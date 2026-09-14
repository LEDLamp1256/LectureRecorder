# T3B speech fixture

`technical-speech-44100-mono.caf` contains: “Lecture recorder tests neural
networks and Fourier transforms for accurate technical transcription.”

It was synthesized locally on macOS 26.6 with `/usr/bin/say` and the system
`Samantha` voice, then converted with
`afconvert -f caff -d LEF32@44100 -c 1`. Only the final CAF is retained. It
is mono Float32 PCM at 44,100 Hz, contains 242,368 frames (about 5.496 seconds),
is 973,568 bytes, and has SHA-256
`3e533c02910303097519875d53e6e4aa3b4b45ad290c3589991daa26b7caeba4`.

The sentence was written for this repository; there is no third-party speech
recording or downloaded sample. The audio is a generated test artifact, not a
redistribution of the Samantha voice itself. Reproduction depends on a macOS
installation providing that voice and may not be byte-identical on future OS
versions.
