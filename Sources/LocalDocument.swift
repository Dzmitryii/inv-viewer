import Foundation

struct LocalDocument<Value: Codable & Equatable> {
    let file: URL
    let limit: Int

    func read(default empty: Value, valid: (Value) -> Bool) throws -> Value {
        try StoreAccess.locked(StoreAccess.root(for: file)) { try readUnlocked(default: empty, valid: valid) }
    }

    // Caller must hold StoreAccess's root lock.
    func readUnlocked(default empty: Value, valid: (Value) -> Bool) throws -> Value {
        guard let data = try StoreAccess.read(file, limit: limit) else { return empty }
        let value = try JSONDecoder().decode(Value.self, from: data)
        guard valid(value) else { throw StudyStoreError.invalid }
        return value
    }

    func write(_ value: Value, replacing previous: Value, default empty: Value,
               valid: (Value) -> Bool) throws {
        guard valid(value) else { throw StudyStoreError.invalid }
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw StudyStoreError.invalid }
        try StoreAccess.locked(StoreAccess.root(for: file)) {
            try StoreAccess.withFileLocks([file.appendingPathExtension("lock")]) {
                guard try readUnlocked(default: empty, valid: valid) == previous else { throw StudyStoreError.changed }
                try StoreAccess.atomicWrite(data, to: file)
            }
        }
    }
}
