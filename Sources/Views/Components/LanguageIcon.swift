import SwiftUI

/// Displays a language icon with uppercase abbreviation in a rounded rectangle.
struct LanguageIcon: View {
    let language: CodeLanguage
    var size: CGFloat = 36

    private var abbreviation: String {
        switch language {
        case .swift:      "SWIFT"
        case .python:     "PY"
        case .javascript: "JS"
        case .typescript: "TS"
        case .java:       "JAVA"
        case .kotlin:     "KT"
        case .go:         "GO"
        case .rust:       "RS"
        case .html:       "HTML"
        case .css:        "CSS"
        case .xml:        "XML"
        case .json:       "JSON"
        case .yaml:       "YAML"
        case .sql:        "SQL"
        case .shell:      "SH"
        case .markdown:   "MD"
        case .vue:        "VUE"
        case .c:          "C"
        case .cpp:        "C++"
        case .csharp:     "C#"
        case .objectivec: "OBJC"
        case .ruby:       "RB"
        case .php:        "PHP"
        case .lua:        "LUA"
        case .dart:       "DART"
        case .scala:      "SCALA"
        case .perl:       "PL"
        case .dockerfile: "DOCK"
        case .powershell: "PS"
        case .diff:       "DIFF"
        case .makefile:   "MAKE"
        case .unknown:    "</>"
        }
    }

    var body: some View {
        let scale: CGFloat = switch abbreviation.count {
        case ...2: 0.38
        case 3: 0.30
        case 4: 0.25
        default: 0.21
        }
        let fontSize = size * scale
        Text(abbreviation)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.2)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}
