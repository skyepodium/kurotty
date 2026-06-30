protocol TerminalSessionAdapter {
    static func makeSession() -> any TerminalSession
}

enum TerminalSessionPlatformNames {
    static let linux = "Linux"
    static let windows = "Windows"
    static let unsupported = "this platform"
}

enum DefaultTerminalSessionAdapter {
    static func makeSession() -> any TerminalSession {
        #if os(macOS)
        DarwinTerminalSessionAdapter.makeSession()
        #elseif os(Linux)
        UnsupportedTerminalSessionAdapter.makeSession(platformName: TerminalSessionPlatformNames.linux)
        #elseif os(Windows)
        UnsupportedTerminalSessionAdapter.makeSession(platformName: TerminalSessionPlatformNames.windows)
        #else
        UnsupportedTerminalSessionAdapter.makeSession(platformName: TerminalSessionPlatformNames.unsupported)
        #endif
    }
}

#if os(macOS)
struct DarwinTerminalSessionAdapter: TerminalSessionAdapter {
    static func makeSession() -> any TerminalSession {
        DarwinPTYTerminalSession()
    }
}
#endif

struct UnsupportedTerminalSessionAdapter: TerminalSessionAdapter {
    static func makeSession() -> any TerminalSession {
        makeSession(platformName: TerminalSessionPlatformNames.unsupported)
    }

    static func makeSession(platformName: String) -> any TerminalSession {
        UnsupportedTerminalSession(platformName: platformName)
    }
}
