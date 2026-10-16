import Crypto

public func digestCount() -> Int { Array(SHA256.hash(data: [1, 2, 3])).count }
