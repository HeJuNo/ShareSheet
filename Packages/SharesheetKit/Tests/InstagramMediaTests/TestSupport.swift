import Foundation

/// Baut eine Seite wie Instagrams Einbettung: `contextJSON` als JSON-escapter String in einem JS-Array.
func embedHTML(_ contextJSON: String) -> String {
    let literal = String(decoding: try! JSONEncoder().encode(contextJSON), as: UTF8.self)
    return #"<script>["PolarisEmbedSimple","init",[],{"contextJSON":\#(literal)}]</script>"#
}
