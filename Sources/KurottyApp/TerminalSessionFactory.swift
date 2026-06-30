enum TerminalSessionFactory {
    static func makeDefaultSession() -> any TerminalSession {
        DefaultTerminalSessionAdapter.makeSession()
    }
}
