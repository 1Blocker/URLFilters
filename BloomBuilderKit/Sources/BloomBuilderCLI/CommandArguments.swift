import BloomBuilderKit

struct BuildInvocation: Equatable {
  let parameters: BloomFilterParameters
  let outputPath: String
  let inputPaths: [String]

  init(
    parameters: BloomFilterParameters,
    outputPath: String,
    inputPaths: [String]
  ) throws {
    guard !inputPaths.isEmpty else {
      throw CommandArgumentError.missingInput
    }
    for (argument, path) in [("--output", outputPath)]
      + inputPaths.map({ ("key-file", $0) })
    {
      guard !path.isEmpty, !path.utf8.contains(0) else {
        throw CommandArgumentError.invalidPath(argument: argument, path: path)
      }
    }

    self.parameters = parameters
    self.outputPath = outputPath
    self.inputPaths = inputPaths
  }
}

enum CommandArgumentError: Error, Equatable, CustomStringConvertible {
  case missingOption(String)
  case repeatedOption(String)
  case unknownOption(String)
  case missingValue(String)
  case invalidDecimal(option: String, value: String)
  case invalidParameters(BloomFilterParametersError)
  case invalidPath(argument: String, path: String)
  case missingInput

  var description: String {
    switch self {
    case .missingOption(let option):
      return "\(option): required option is missing"
    case .repeatedOption(let option):
      return "\(option): option may only be supplied once"
    case .unknownOption(let option):
      return "\(String(reflecting: option)): unknown option"
    case .missingValue(let option):
      return "\(option): requires a value"
    case .invalidDecimal(let option, let value):
      return "\(option): \(String(reflecting: value)) must be an ASCII decimal in 0...4294967295"
    case .invalidParameters(.bitCountMustBePositive):
      return "--bit-count: must be positive"
    case .invalidParameters(.hashCountMustBePositive):
      return "--hash-count: must be positive"
    case .invalidParameters(let error):
      return "parameters: \(error)"
    case .invalidPath(let argument, let path):
      return "\(argument): \(String(reflecting: path)) must be a nonempty path without NUL bytes"
    case .missingInput:
      return "key-file: at least one input path is required"
    }
  }
}

enum CommandArguments: Equatable {
  case help
  case build(BuildInvocation)

  static let usage = """
    Usage: bloombuilder --bit-count <n> --hash-count <n> \
    --murmur-seed <n> --output <path> <key-file>...

    Build a raw packed Bloom vector from one or more LF-delimited key files.
    All numeric options are required ASCII decimals that fit UInt32.
    Bit and hash counts must be positive; seed 0 is valid.
    Keys are raw bytes: no trimming, decoding or normalization is performed.
    Nonempty files must end with LF; empty lines and CR bytes are rejected.
    The output contains only the vector bytes; parameters must be kept separately.
    An existing output entry, including a symlink, is never replaced.

    Options accept either --name <value> or --name=<value>.
    Use -- before input paths beginning with a dash, and --output=-name for
    an output path beginning with a dash. Options may precede or follow inputs.
    --help prints this usage. Arguments after -- are always input paths.

    Exit status: 0 for success or help; 1 for every failure.
    Failures produce one diagnostic on stderr. The success summary on stdout
    is informational and is not a machine-readable interface.
    """ + "\n"

  static func parse(_ arguments: [String]) throws -> Self {
    var values: [Option: String] = [:]
    var inputPaths: [String] = []
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      index += 1

      if argument == "--" {
        inputPaths.append(contentsOf: arguments[index...])
        break
      }
      if argument == "--help" {
        return .help
      }
      guard argument.hasPrefix("-") else {
        inputPaths.append(argument)
        continue
      }

      let parts = argument.split(
        separator: "=",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      let name = String(parts[0])
      guard let option = Option(rawValue: name) else {
        throw CommandArgumentError.unknownOption(name)
      }
      guard values[option] == nil else {
        throw CommandArgumentError.repeatedOption(name)
      }

      if parts.count == 2 {
        values[option] = String(parts[1])
      } else {
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
          throw CommandArgumentError.missingValue(name)
        }
        values[option] = arguments[index]
        index += 1
      }
    }

    func required(_ option: Option) throws -> String {
      guard let value = values[option] else {
        throw CommandArgumentError.missingOption(option.rawValue)
      }
      return value
    }

    func decimal(_ option: Option) throws -> UInt32 {
      let value = try required(option)
      guard
        !value.isEmpty,
        value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
        let number = UInt32(value)
      else {
        throw CommandArgumentError.invalidDecimal(option: option.rawValue, value: value)
      }
      return number
    }

    let bitCount = try decimal(.bitCount)
    let hashCount = try decimal(.hashCount)
    let murmurSeed = try decimal(.murmurSeed)
    let outputPath = try required(.output)
    let parameters: BloomFilterParameters
    do {
      parameters = try BloomFilterParameters(
        bitCount: bitCount,
        hashCount: hashCount,
        murmurSeed: murmurSeed
      )
    } catch let error as BloomFilterParametersError {
      throw CommandArgumentError.invalidParameters(error)
    }

    return .build(
      try BuildInvocation(
        parameters: parameters,
        outputPath: outputPath,
        inputPaths: inputPaths
      )
    )
  }

  private enum Option: String {
    case bitCount = "--bit-count"
    case hashCount = "--hash-count"
    case murmurSeed = "--murmur-seed"
    case output = "--output"
  }
}
