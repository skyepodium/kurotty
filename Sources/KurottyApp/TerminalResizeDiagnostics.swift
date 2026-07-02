import Foundation
import KurottyCore

struct TerminalResizeTrace: CustomStringConvertible {
    let requestedColumns: Int
    let requestedRows: Int
    let clampedColumns: Int
    let clampedRows: Int
    let cellSize: TerminalFrameSize?
    let viewSize: TerminalFrameSize?
    let ioctlResult: Int32
    let ioctlErrno: Int32?
    let didSendSIGWINCH: Bool

    init(
        requestedColumns: Int,
        requestedRows: Int,
        cellSize: TerminalFrameSize?,
        viewSize: TerminalFrameSize?,
        ioctlResult: Int32,
        ioctlErrno: Int32?,
        didSendSIGWINCH: Bool
    ) {
        self.requestedColumns = requestedColumns
        self.requestedRows = requestedRows
        clampedColumns = Self.clampedWinsizeDimension(requestedColumns)
        clampedRows = Self.clampedWinsizeDimension(requestedRows)
        self.cellSize = cellSize
        self.viewSize = viewSize
        self.ioctlResult = ioctlResult
        self.ioctlErrno = ioctlErrno
        self.didSendSIGWINCH = didSendSIGWINCH
    }

    var description: String {
        var fields = [
            "requested=\(requestedColumns)x\(requestedRows)",
            "clamped=\(clampedColumns)x\(clampedRows)",
            "cell=\(format(size: cellSize))",
            "view=\(format(size: viewSize))",
            "ioctl=\(ioctlResult)",
        ]
        if let ioctlErrno {
            fields.append("errno=\(ioctlErrno)")
        }
        fields.append("sigwinch=\(didSendSIGWINCH ? "sent" : "not-sent")")
        return fields.joined(separator: " ")
    }

    private static func clampedWinsizeDimension(_ dimension: Int) -> Int {
        min(max(1, dimension), Int(UInt16.max))
    }

    private func format(size: TerminalFrameSize?) -> String {
        guard let size else { return "unavailable" }
        return String(format: "%0.2fx%0.2f", size.width, size.height)
    }
}

extension TerminalResizeCycleSnapshot {
    init?(
        trace: TerminalResizeTrace,
        traceID: String? = nil,
        source: String? = nil,
        timestamp: TimeInterval? = nil,
        screenColumns: Int,
        screenRows: Int,
        rendererColumns: Int,
        rendererRows: Int,
        rendererDrawableSize: TerminalFrameSize? = nil,
        rendererFrameSize: TerminalFrameSize? = nil
    ) {
        guard let viewSize = trace.viewSize,
              let cellSize = trace.cellSize
        else {
            return nil
        }

        self.init(
            traceID: traceID,
            source: source,
            timestamp: timestamp,
            viewportSize: viewSize,
            cellSize: cellSize,
            ptyColumns: trace.clampedColumns,
            ptyRows: trace.clampedRows,
            screenColumns: screenColumns,
            screenRows: screenRows,
            rendererColumns: rendererColumns,
            rendererRows: rendererRows,
            rendererDrawableSize: rendererDrawableSize,
            rendererFrameSize: rendererFrameSize
        )
    }
}
