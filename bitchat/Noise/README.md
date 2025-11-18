# Unnamed Noise_XX_25519_ChaChaPoly_SHA256 Implementation in Swift

## Running Tests

This implementation comes with a bare-minimum test harness, intended to ensure that it at least passes the test vectors as stipulated by both [cacophony and snow](https://github.com/mcginty/snow/tree/main/tests).

In order to run the tests:

```bash
swiftc -o NoiseTestRunner -D NOISE_TESTS NoiseTestRunner.swift NoiseProtocol.swift ../Utils/Data+SHA256.swift ../Protocols/BinaryEncodingUtils.swift
./NoiseTestRunner
rm NoiseTestRunner
```
