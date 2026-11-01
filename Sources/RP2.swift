// Copyright (c) 2026 tkagy <248091500+tkagy@users.noreply.github.com>
// SPDX-License-Identifier: MIT

/// Common firmware entry point for RP-series chips.
// @main is not required because resetHandler invokes main through reset().
enum RP2 {
    static func initialize() -> Never {
        main()
    }

    static func main() -> Never {
        while true {}
    }

    static func reset() -> Never {
        initialize()
    }
}

@_cdecl("rp2_reset")
func resetHandler() -> Never {
    RP2.reset()
}
