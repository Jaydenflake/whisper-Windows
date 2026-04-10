#!/usr/bin/env python3

import argparse
import math
import multiprocessing as mp
import os
import time


def worker(seconds: float) -> None:
    deadline = time.time() + seconds
    value = 0.0
    while time.time() < deadline:
        value = math.sin(value + 1.23456789) * math.cos(value + 9.87654321)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    args = parser.parse_args()

    children = [mp.Process(target=worker, args=(args.seconds,)) for _ in range(args.workers)]
    for child in children:
        child.start()
    for child in children:
        child.join()


if __name__ == "__main__":
    main()
