-- Low-latency whisper dictation hotkey via a native capture daemon.

if hs.ipc and not hs.ipc.cliStatus() then
  hs.ipc.cliInstall()
end

hs.alert.defaultStyle = {
  fillColor       = { white = 0.08, alpha = 0.65 },
  strokeColor     = { white = 1.0, alpha = 0.10 },
  strokeWidth     = 0,
  radius          = 26,
  atScreenEdge    = 0,
  textColor       = { white = 1.0, alpha = 0.95 },
  textFont        = ".AppleSystemUIFont",
  textSize        = 22,
  padding         = 14,
  fadeInDuration  = 0.08,
  fadeOutDuration = 0.08,
}

local configPath = os.getenv("HOME") .. "/Library/Application Support/WhisperDictation/config.json"
local config = nil
local controlBin = nil
local activeTasks = {}
local pendingCount = 0
local recordState = "idle"
local resultPoller = nil
local recordingOverlay = nil
local lastHealthWarningAt = 0

local function alert(message)
  hs.alert.show(message, 0.95)
end

local function loadConfig()
  local file = io.open(configPath, "r")
  if not file then
    return nil, "Dictation config not installed"
  end

  local raw = file:read("*a")
  file:close()

  local decoded = hs.json.decode(raw)
  if not decoded then
    return nil, "Failed to parse dictation config"
  end

  return decoded, nil
end

local function showRecordingOverlay()
  if recordingOverlay then return end

  local screen = hs.screen.mainScreen()
  local frame = screen:frame()
  local width, height = 150, 42
  local x = frame.x + (frame.w - width) / 2
  local y = frame.y + frame.h - height - 20
  local canvas = hs.canvas.new({x = x, y = y, w = width, h = height})

  canvas:appendElements({
    action = "fill",
    type = "rectangle",
    fillColor = {white = 0.08, alpha = 0.85},
    roundedRectRadii = {xRadius = height/2, yRadius = height/2},
  }, {
    action = "fill",
    type = "circle",
    center = {x = 22, y = height/2},
    radius = 7.2,
    fillColor = {red = 1, green = 0.2, blue = 0.2, alpha = 0.9},
    strokeColor = {red = 1, green = 0.2, blue = 0.2, alpha = 1},
    strokeWidth = 0,
  }, {
    action = "fill",
    type = "text",
    text = "Recording",
    textFont = hs.alert.defaultStyle.textFont,
    textSize = 19,
    textColor = hs.alert.defaultStyle.textColor,
    textAlignment = "center",
    frame = {x = 32, y = 10, w = width - 44, h = height - 18},
  })

  canvas:show()
  recordingOverlay = canvas
end

local function hideRecordingOverlay()
  if recordingOverlay then
    recordingOverlay:delete()
    recordingOverlay = nil
  end
end

local function normalizeTranscript(text)
  if not text then
    return nil
  end

  local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return nil
  end

  local marker = trimmed:upper():gsub("[%s_%-]", ""):gsub("[%[%]%(%)]+", "")
  if marker == "BLANKAUDIO" or marker == "NOSPEECH" or marker == "SILENCE" then
    return nil
  end

  if not trimmed:match("[%w]") then
    return nil
  end

  return trimmed
end

local function pasteTranscript(text)
  text = normalizeTranscript(text)
  if not text then
    alert("No Output")
    return
  end

  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
  alert(pendingCount > 0 and string.format("Transcript Ready (%d)", pendingCount) or "Transcript Ready")
end

local function maybeWarnAboutStatus(status)
  if not status or not status.lowDiskSpaceMessage then
    return
  end

  local now = hs.timer.secondsSinceEpoch()
  if (now - lastHealthWarningAt) < 300 then
    return
  end

  lastHealthWarningAt = now
  alert(status.lowDiskSpaceMessage)
end

local function runControl(command, callback)
  if not controlBin or not hs.fs.attributes(controlBin) then
    callback(nil, "Control binary not installed")
    return
  end

  local task = nil
  task = hs.task.new(controlBin, function(exitCode, stdout, stderr)
    activeTasks[tostring(task)] = nil

    if stderr and stderr ~= "" then
      hs.printf("dictation ctl stderr: %s", stderr)
    end

    local response = nil
    if stdout and stdout ~= "" then
      response = hs.json.decode(stdout)
    end

    if not response then
      callback(nil, "Invalid control response")
      return
    end

    if exitCode ~= 0 and (not response.ok) then
      callback(response, response.error or "Control command failed")
      return
    end

    callback(response, nil)
  end, {command})

  if not task then
    callback(nil, "Failed to launch control binary")
    return
  end

  activeTasks[tostring(task)] = task
  task:start()
end

local function stopResultPolling()
  if resultPoller then
    resultPoller:stop()
    resultPoller = nil
  end
end

local function pollForResults()
  runControl("next-result", function(response, err)
    if err or not response then
      if err then
        hs.printf("dictation poll error: %s", err)
      end
      return
    end

    pendingCount = response.pendingCount or pendingCount

    if response.resultAvailable and response.result then
      pendingCount = math.max((response.pendingCount or pendingCount) - 1, 0)
      local result = response.result
      if result.text and result.text ~= "" then
        pasteTranscript(result.text)
      elseif result.errorMessage and result.errorMessage ~= "" then
        alert(result.errorMessage)
        hs.printf("dictation error: %s", result.errorMessage)
        if result.salvagePath and result.salvagePath ~= "" then
          hs.printf("dictation salvage: %s", result.salvagePath)
        end
      elseif result.salvagePath then
        alert("Transcription Failed")
        hs.printf("dictation salvage: %s", result.salvagePath)
      else
        alert("No Output")
      end
    end

    if pendingCount <= 0 and recordState == "idle" then
      stopResultPolling()
    end
  end)
end

local function ensureResultPolling()
  if resultPoller then
    return
  end

  resultPoller = hs.timer.doEvery(0.15, pollForResults)
end

local function warmupDaemon()
  runControl("warmup", function(_, err)
    if err then
      hs.printf("dictation warmup skipped: %s", err)
    end
  end)
end

local function restoreState()
  runControl("status", function(response, err)
    if err or not response or not response.status then
      return
    end

    pendingCount = response.pendingCount or 0
    if response.status.recording then
      recordState = "recording"
      showRecordingOverlay()
    else
      recordState = "idle"
      hideRecordingOverlay()
    end

    maybeWarnAboutStatus(response.status)

    if pendingCount > 0 then
      ensureResultPolling()
    end
  end)
end

local function startRecording()
  if recordState == "recording" then
    alert("Recording")
    return
  end

  if recordState == "starting" or recordState == "stopping" then
    return
  end

  recordState = "starting"
  alert("Starting")

  runControl("start", function(response, err)
    if err or not response or not response.ok then
      recordState = "idle"
      hideRecordingOverlay()
      alert(err or response.error or "Start failed")
      return
    end

    recordState = "recording"
    showRecordingOverlay()
    maybeWarnAboutStatus(response.status)
    alert("Recording")
  end)
end

local function stopRecording(discard)
  if recordState ~= "recording" then
    alert("No Session")
    return
  end

  recordState = "stopping"
  hideRecordingOverlay()

  runControl(discard and "cancel" or "stop", function(response, err)
    recordState = "idle"
    if err or not response or not response.ok then
      alert(err or response.error or "Stop failed")
      return
    end

    pendingCount = response.pendingCount or pendingCount
    if discard then
      alert("Recording Canceled")
      return
    end

    maybeWarnAboutStatus(response.status)
    ensureResultPolling()
    alert(string.format("Processing Audio (%d)", pendingCount))
  end)
end

config, err = loadConfig()
if config then
  controlBin = config.controlBinaryPath
  hs.timer.doAfter(0.05, warmupDaemon)
  hs.timer.doAfter(0.15, restoreState)
  alert("Dictation Ready")
else
  alert(err or "Dictation config missing")
end

hs.hotkey.bind({"cmd"}, ".", function()
  if recordState == "recording" then
    stopRecording(false)
  else
    startRecording()
  end
end)

hs.hotkey.bind({"cmd"}, ",", function()
  stopRecording(true)
end)
