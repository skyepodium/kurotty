enum TerminalSessionFactory {
    static func makeDefaultSession() -> any TerminalSession {
        #if os(macOS)
        ShellSession()
        #else
        UnsupportedTerminalSession()
        #endif
    }
}
