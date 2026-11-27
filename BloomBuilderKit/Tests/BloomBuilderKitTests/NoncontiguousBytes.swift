struct NoncontiguousBytes: Collection {
  // Intentionally use Collection's default nil contiguous-storage result.
  private static let indexOffset = 7

  private let storage: [UInt8]

  init(_ storage: [UInt8]) {
    self.storage = storage
  }

  var startIndex: Int {
    Self.indexOffset
  }

  var endIndex: Int {
    startIndex + storage.count
  }

  func index(after index: Int) -> Int {
    index + 1
  }

  subscript(index: Int) -> UInt8 {
    storage[index - startIndex]
  }
}
