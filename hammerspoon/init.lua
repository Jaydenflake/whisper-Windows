-- Voice dictation hotkey for whisper.cpp via Hammerspoon
if hs.ipc and not hs.ipc.cliStatus() then
  hs.ipc.cliInstall()
end

hs.alert.defaultStyle = {
  fillColor      = { white = 0.08, alpha = 0.65 },
  strokeColor    = { white = 1.0, alpha = 0.10 },
  strokeWidth    = 0,
  radius         = 26,
  atScreenEdge   = 0, -- center
  textColor      = { white = 1.0, alpha = 0.95 },
  textFont       = ".AppleSystemUIFont",
  textSize       = 22,
  padding        = 14,
  fadeInDuration = 0.08,
  fadeOutDuration = 0.08
}

local ffmpegPath  = "/opt/homebrew/bin/ffmpeg"
local whisperBin  = "/Users/gabrielhansen/MyProjects/whisper.cpp/build/bin/whisper-cli"
local modelPath   = "/Users/gabrielhansen/MyProjects/whisper.cpp/models/ggml-small.en.bin"
-- Resolve the microphone by name so virtual devices (for example Teams) do not
-- break recording when AVFoundation reorders indexes.
local preferredAudioDevice = "MacBook Pro Microphone"
local fallbackAudioDevice = ":0"

local recordTask = nil
local activeSession = nil
local pendingCount = 0
local recordingOverlay = nil
local salvageDir = os.getenv("HOME") .. "/Documents/WhisperSalvage"

local function alert(msg)
  hs.alert.show(msg, 0.95)
end

local function resolveAudioDevice()
  local cmd = string.format("%q -f avfoundation -list_devices true -i '' 2>&1", ffmpegPath)
  local output = hs.execute(cmd)
  local inAudioDevices = false

  for line in output:gmatch("[^\r\n]+") do
    if line:find("AVFoundation audio devices:", 1, true) then
      inAudioDevices = true
    elseif inAudioDevices then
      local idx, name = line:match("%]%s*%[(%d+)%]%s+(.+)$")
      if idx and name == preferredAudioDevice then
        return ":" .. idx
      end
    end
  end

  hs.printf(
    "Preferred audio device '%s' not found; falling back to %s",
    preferredAudioDevice,
    fallbackAudioDevice
  )
  return fallbackAudioDevice
end

local function showRecordingOverlay()
  if recordingOverlay then return end
  local screen = hs.screen.mainScreen()
  local frame = screen:frame()
  local width, height = 150, 42
  local x = frame.x + (frame.w - width) / 2
  local y = frame.y + frame.h - height - 20 -- bottom with margin
  local canvas = hs.canvas.new({x = x, y = y, w = width, h = height})
  canvas:appendElements({
    action = "fill",
    type = "rectangle",
    fillColor = {white = 0.08, alpha = 0.85},
    roundedRectRadii = {xRadius = height/2, yRadius = height/2},
  },
  {
    action = "fill",
    type = "circle",
    center = {x = 22, y = height/2},
    radius = 7.2,
    fillColor = {red = 1, green = 0.2, blue = 0.2, alpha = 0.9},
    strokeColor = {red = 1, green = 0.2, blue = 0.2, alpha = 1},
    strokeWidth = 0
  },
  {
    action = "fill",
    type = "text",
    text = "Recording",
    textFont = hs.alert.defaultStyle.textFont,
    textSize = 19,
    textColor = hs.alert.defaultStyle.textColor,
    textAlignment = "center",
    frame = {x = 32, y = 10, w = width - 44, h = height - 18}
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

local function clearTempFiles(session)
  if not session then return end
  if session.tmpWav and hs.fs.attributes(session.tmpWav) then os.remove(session.tmpWav) end
  if session.outBase and hs.fs.attributes(session.outBase .. ".txt") then
    os.remove(session.outBase .. ".txt")
  end
end

local function ensureSalvageDir()
  if not hs.fs.attributes(salvageDir) then
    hs.fs.mkdir(salvageDir)
  end
end

local function salvageSessionFiles(session, tag)
  if not session then return end
  ensureSalvageDir()
  local stamp = os.date("%Y%m%d-%H%M%S")
  local base = string.format("%s/whisper-%s-%s", salvageDir, stamp, tag or "error")
  local wavOut = base .. ".wav"
  local txtOut = base .. ".txt"

  if session.tmpWav and hs.fs.attributes(session.tmpWav) then
    os.rename(session.tmpWav, wavOut)
    hs.printf("salvage wav: %s", wavOut)
  end
  local txtIn = session.outBase and (session.outBase .. ".txt") or nil
  if txtIn and hs.fs.attributes(txtIn) then
    os.rename(txtIn, txtOut)
    hs.printf("salvage txt: %s", txtOut)
  end
end

local function pasteResult(text)
  if not text or text == "" then
    alert("No Output")
    return
  end
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
  if pendingCount > 0 then
    alert(string.format("Transcript Ready (%d)", pendingCount))
  else
    alert("Transcript Ready")
  end
end

local function runWhisper(session)
  if not session then return end

  if session.skipTranscribe then
    clearTempFiles(session)
    alert("Discarded Audio")
    return
  end

  if not session.tmpWav or not session.outBase then
    alert("Missing audio for transcription")
    salvageSessionFiles(session, "missing-audio")
    return
  end

  pendingCount = pendingCount + 1
  alert(string.format("Processing Audio (%d)", pendingCount))

  local args = {
    "-m", modelPath,
    "-f", session.tmpWav,
    "--output-txt",
    "--output-file", session.outBase,
  }

  hs.task.new(whisperBin, function(_, stdout, stderr)
    if stderr and stderr ~= "" then
      hs.printf("whisper stderr: %s", stderr)
    end
    local file = io.open(session.outBase .. ".txt", "r")
    local text = nil
    if file then
      text = file:read("*a")
      file:close()
    end
    if text and text:gsub("%s+", "") ~= "" then
      clearTempFiles(session)
    else
      salvageSessionFiles(session, "empty-output")
    end
    pendingCount = math.max(pendingCount - 1, 0)
    pasteResult(text and text:gsub("%s+$", ""))
  end, args):start()
end

local function startRecording()
  if not hs.fs.displayName(ffmpegPath) then
    alert("ffmpeg not found")
    return
  end
  if not hs.fs.displayName(whisperBin) then
    alert("whisper-cli not built")
    return
  end

  if activeSession then
    alert("Recording")
    return
  end

  local session = {
    tmpWav = os.tmpname() .. ".wav",
    outBase = os.tmpname(),
    skipTranscribe = false,
    stopping = false
  }
  activeSession = session
  local audioDevice = resolveAudioDevice()

  local args = {
    "-f", "avfoundation",
    "-i", audioDevice,
    "-ac", "1",
    "-ar", "16000",
    "-c:a", "pcm_s16le",
    "-y", session.tmpWav
  }

  recordTask = hs.task.new(ffmpegPath, function(exitCode, stdout, stderr)
    if stderr and stderr ~= "" then
      hs.printf("ffmpeg stderr: %s", stderr)
    end
    recordTask = nil
    local okExit = (exitCode == 0 or exitCode == 15 or exitCode == 143 or exitCode == 255)
    -- ffmpeg exits with 15/143 when we terminate it; some environments surface 255, treat as success too
    if not okExit then
      hs.printf("Recorder exit code %s", tostring(exitCode))
      alert("Recorder Error (saved)")
      salvageSessionFiles(session, "recorder-" .. tostring(exitCode))
    if activeSession == session then
      activeSession = nil
    end
    hideRecordingOverlay()
    return
  end
  if activeSession == session then
    activeSession = nil
  end
  hideRecordingOverlay()
  runWhisper(session)
end, args)

  recordTask:start()
  showRecordingOverlay()
  alert("Recording")
end

local function stopRecording(skipTranscribe)
  if not activeSession then
    alert("No Session")
    return
  end
  if activeSession.stopping then
    return
  end
  if activeSession then
    activeSession.skipTranscribe = skipTranscribe or false
    activeSession.stopping = true
  end
  if recordTask and recordTask:isRunning() then
    recordTask:terminate()
  end
  hideRecordingOverlay()
  if skipTranscribe then
    alert("Recording Canceled")
  else
    alert("Recording Stopped")
  end
end

hs.hotkey.bind({"cmd"}, ".", function()
  if activeSession then
    stopRecording(false)
  else
    startRecording()
  end
end)

hs.hotkey.bind({"cmd"}, ",", function()
  stopRecording(true)
end)

alert("Dictation Ready")
