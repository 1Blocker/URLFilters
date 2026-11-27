enum CommandOutcome {
  case help
  case built(BloomBuildSummary)
  case failed(any Error)
}

enum CommandResultError: Error, Equatable, CustomStringConvertible {
  case standardStreamWrite(name: String, reason: String)

  var description: String {
    switch self {
    case .standardStreamWrite(let name, let reason):
      return "\(name): cannot write standard stream: \(reason)"
    }
  }
}

struct CommandResult: Equatable {
  let exitStatus: Int32
  let standardOutput: String
  let standardError: String
  private let standardOutputIsInformational: Bool

  init(_ outcome: CommandOutcome) {
    switch outcome {
    case .help:
      exitStatus = 0
      standardOutput = CommandArguments.usage
      standardError = ""
      standardOutputIsInformational = false
    case .built(let summary):
      exitStatus = 0
      standardOutput = "Wrote \(summary.byteCount) bytes to "
        + "\(String(reflecting: summary.outputPath)) "
        + "from \(summary.inputFileCount) input file(s).\n"
      standardError = ""
      standardOutputIsInformational = true
    case .failed(let error):
      exitStatus = 1
      standardOutput = ""
      let message = String(describing: error)
        .split(whereSeparator: \.isNewline)
        .joined(separator: " ")
      standardError = "bloombuilder: \(message)\n"
      standardOutputIsInformational = false
    }
  }

  func write(to outputDescriptor: Int32, errorDescriptor: Int32) -> Int32 {
    do {
      try CommandFileIO.writeText(standardOutput, to: outputDescriptor)
    } catch {
      if !standardOutputIsInformational {
        let failure = CommandResult(.failed(
          CommandResultError.standardStreamWrite(name: "stdout", reason: String(describing: error))
        ))
        try? CommandFileIO.writeText(failure.standardError, to: errorDescriptor)
        return failure.exitStatus
      }
    }
    try? CommandFileIO.writeText(standardError, to: errorDescriptor)
    return exitStatus
  }
}

enum BloomBuilderCommand {
  static func run(arguments: [String]) -> CommandResult {
    do {
      switch try CommandArguments.parse(arguments) {
      case .help:
        return CommandResult(.help)
      case .build(let invocation):
        return CommandResult(.built(try BloomBuild.run(invocation)))
      }
    } catch {
      return CommandResult(.failed(error))
    }
  }
}
