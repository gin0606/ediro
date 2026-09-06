import Testing

// MainActor は await 中に別テストを実行する。描画やフォント走査で他のテストの
// 非同期処理を待たせないよう、UI テスト全体を同じ直列スイートに置く。
@Suite(.serialized)
struct AppKitTests {}
