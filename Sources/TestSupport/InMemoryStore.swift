import EdiroCore
import Foundation

/// ディスクを触らない設定の置き場所。テストはこちらを使う。
public final class InMemoryStore: KeyValueStore {
  private var values: [String: Any]

  public init(_ values: [String: Any] = [:]) {
    self.values = values
  }

  public func object(forKey key: String) -> Any? { values[key] }
  public func string(forKey key: String) -> String? { values[key] as? String }
  public func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
  public func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
  public func set(_ value: Any?, forKey key: String) { values[key] = value }
}
