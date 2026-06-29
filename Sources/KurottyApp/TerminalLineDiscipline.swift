import Darwin

enum TerminalLineDiscipline {
    static func canReceiveTerminalResponseWithoutEcho(localFlags: tcflag_t) -> Bool {
        localFlags & tcflag_t(ECHO) == 0
    }
}
