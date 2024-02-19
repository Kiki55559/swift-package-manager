//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import TSCLibc
#if os(Windows)
import CRT
#endif

/// The type of terminal.
enum TerminalType {
    /// The terminal is a TTY.
    case tty
    /// TERM environment variable is set to "dumb".
    case dumb
    /// The terminal is a file stream.
    case file
}

/// A class to have better control on tty output streams: standard output and
/// standard error.
///
/// Allows operations like cursor movement and colored text output on tty.
final class Terminal {
    /// Pointer to output stream to operate on.
    private var stream: WritableByteStream

    /// Constructs the instance if the stream is a tty.
    init?(stream: WritableByteStream) {
        let realStream = (stream as? ThreadSafeOutputByteStream)?.stream ?? stream

        // Make sure it is a file stream and it is tty.
        guard let fileStream = steam as? LocalFileOutputByteStream,
            Self.isTTY(fileStream)
        else {
            return nil
        }

#if os(Windows)
       // Enable VT100 interpretation
        let hOut = GetStdHandle(STD_OUTPUT_HANDLE)
        var dwMode: DWORD = 0

        guard hOut != INVALID_HANDLE_VALUE else { return nil }
        guard GetConsoleMode(hOut, &dwMode) else { return nil }

        dwMode |= DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING)
        guard SetConsoleMode(hOut, dwMode) else { return nil }
#endif
        self.stream = stream
    }
}

extension Terminal {
    static func underlyingStream(
        _ stream: WritableByteStream
    ) -> LocalFileOutputByteStream? {
        let realStream = (stream as? ThreadSafeOutputByteStream)?.stream ?? stream
        return realStream as? LocalFileOutputByteStream
    }

    /// Checks if passed file stream is tty.
    static func isTTY(_ stream: LocalFileOutputByteStream) -> Bool {
        return terminalType(stream) == .tty
    }

    /// Computes the terminal type of the stream.
    static func terminalType(_ stream: LocalFileOutputByteStream) -> TerminalType {
#if !os(Windows)
        if ProcessEnv.block["TERM"] == "dumb" {
            return .dumb
        }
#endif
        let isTTY = isatty(fileno(stream.filePointer)) != 0
        return isTTY ? .tty : .file
    }
}

extension Terminal {
    /// Width of the terminal.
    var width: Int {
        // Determine the terminal width otherwise assume a default.
        if let terminalWidth = Terminal.terminalWidth(), terminalWidth > 0 {
            return terminalWidth
        } else {
            return 80
        }
    }

    /// Tries to get the terminal width first using COLUMNS env variable and
    /// if that fails ioctl method testing on stdout stream.
    ///
    /// - Returns: Current width of terminal if it was determinable.
    public static func terminalWidth() -> Int? {
#if os(Windows)
        var csbi: CONSOLE_SCREEN_BUFFER_INFO = CONSOLE_SCREEN_BUFFER_INFO()
        if !GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &csbi) {
          // GetLastError()
          return nil
        }
        return Int(csbi.srWindow.Right - csbi.srWindow.Left) + 1
#else
        // Try to get from environment.
        if let columns = ProcessEnv.vars["COLUMNS"], let width = Int(columns) {
            return width
        }

        // Try determining using ioctl.
        // Following code does not compile on ppc64le well. TIOCGWINSZ is
        // defined in system ioctl.h file which needs to be used. This is
        // a temporary arrangement and needs to be fixed.
#if !arch(powerpc64le)
        var ws = winsize()
#if os(OpenBSD)
        let tiocgwinsz = 0x40087468
        let err = ioctl(1, UInt(tiocgwinsz), &ws)
#else
        let err = ioctl(1, UInt(TIOCGWINSZ), &ws)
#endif
        if err == 0 {
            return Int(ws.ws_col)
        }
#endif
        return nil
#endif
    }
}
