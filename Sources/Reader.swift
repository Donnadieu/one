import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers

/// Renders the assistant's Markdown replies: headings, bullet and numbered lists, quotes, code blocks,
/// simple tables and rules, with inline bold/italic/code/links.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 15
    enum Block: Hashable {
        case heading(Int, String)
        case bullet(Int, String)
        case numbered(Int, String, String)
        case quote(String)
        case code(String)
        case table([[String]])
        case rule
        case para(String)
    }

    static func blocks(_ src: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        var table: [[String]] = []
        func flushPara() {
            if !para.isEmpty {
                out.append(.para(para.joined(separator: " ")))
                para = []
            }
        }
        func flushTable() {
            if !table.isEmpty {
                out.append(.table(table))
                table = []
            }
        }
        for raw in src.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code {
                    out.append(.code(c.joined(separator: "\n")))
                    code = nil
                } else {
                    flushPara()
                    flushTable()
                    code = []
                }
                continue
            }
            if code != nil {
                code!.append(raw)
                continue
            }
            if line.hasPrefix("|") && line.hasSuffix("|") {
                flushPara()
                let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if line.isEmpty {
                flushPara()
                continue
            }
            let indent = raw.prefix { $0 == " " }.count / 2
            if let r = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flushPara()
                out.append(.heading(line[r].count - 1, String(line[r.upperBound...])))
            } else if line == "---" || line == "***" || line == "___" {
                flushPara()
                out.append(.rule)
            } else if let r = line.range(of: #"^[-*+•] "#, options: .regularExpression) {
                flushPara()
                out.append(.bullet(indent, String(line[r.upperBound...])))
            } else if let r = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flushPara()
                out.append(.numbered(indent, String(line[r].dropLast(2)), String(line[r.upperBound...])))
            } else if line.hasPrefix(">") {
                flushPara()
                out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushPara()
        flushTable()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let l, let t):
                    Text(Self.inline(t)).font(.system(size: size + CGFloat(max(0, 4 - l)) * 2, weight: .semibold)).padding(.top, 4)
                case .bullet(let ind, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(ind) * 16)
                case .numbered(let ind, let n, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(ind) * 16)
                case .quote(let t):
                    Text(Self.inline(t)).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2) }
                case .code(let c):
                    Text(c).font(.system(size: size - 2, design: .monospaced)).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06)))
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                            GridRow {
                                ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                                    Text(Self.inline(c)).fontWeight(i == 0 ? .semibold : .regular)
                                }
                            }
                            if i == 0 { Divider() }
                        }
                    }
                case .rule: Divider()
                case .para(let t): Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: size))
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
    }
}
