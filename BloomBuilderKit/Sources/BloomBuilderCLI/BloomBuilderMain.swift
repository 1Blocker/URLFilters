#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@main
enum BloomBuilderMain {
  static func main() {
    signal(SIGPIPE, SIG_IGN)
    let result = BloomBuilderCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
    exit(result.write(to: STDOUT_FILENO, errorDescriptor: STDERR_FILENO))
  }
}
