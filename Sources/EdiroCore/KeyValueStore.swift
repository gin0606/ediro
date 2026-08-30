import Foundation

/// 設定の置き場所。
///
/// `UserDefaults` を直に見ないのは、テストが本物の suite を作らずに済ませるため。
/// suite を使うと `~/Library/Preferences` に plist が残り、走っている最中は
/// 消せないので掃除を次の起動へ先送りすることになる。差し替えられるように
/// しておけば、テストはディスクを触らずに済む。
public protocol KeyValueStore: AnyObject {
  func object(forKey key: String) -> Any?
  func string(forKey key: String) -> String?
  func double(forKey key: String) -> Double
  func integer(forKey key: String) -> Int
  func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}
