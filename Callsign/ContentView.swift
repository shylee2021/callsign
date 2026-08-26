//
//  ContentView.swift
//  Callsign
//
//  Created by shylee on 8/25/26.
//

import AppKit
import SwiftUI

enum TagPosition: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, leftCenter, rightCenter, bottomLeft, bottomCenter, bottomRight

    var id: Self { self }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .leftCenter: "Left Center"
        case .rightCenter: "Right Center"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
}

enum TagLabel: String, CaseIterable, Identifiable {
    case appName, windowTitle, iconOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .appName: "App Name"
        case .windowTitle: "Window Name"
        case .iconOnly: "Icon Only"
        }
    }
}

struct TagConfiguration: Hashable {
    var position: TagPosition
    var label: TagLabel
    var overlap: Double
    var scale: Double
    var appearDelay: Double
    var disappearDelay: Double
    var offsetX: Double
    var offsetY: Double
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    var textRed: Double
    var textGreen: Double
    var textBlue: Double
    var textAlpha: Double

    static let `default` = TagConfiguration(
        position: .bottomCenter,
        label: .appName,
        overlap: 0.5,
        scale: 1,
        appearDelay: 0,
        disappearDelay: 0,
        offsetX: 0,
        offsetY: 0,
        red: 0.08,
        green: 0.08,
        blue: 0.09,
        alpha: 0.85,
        textRed: 1,
        textGreen: 1,
        textBlue: 1,
        textAlpha: 1)
}

struct ContentView: View {
    @StateObject private var probe = MissionControlProbe()
    @AppStorage("tag.position") private var tagPosition = TagPosition.bottomCenter.rawValue
    @AppStorage("tag.label") private var tagLabel = TagLabel.appName.rawValue
    @AppStorage("tag.overlap") private var tagOverlap = 0.5
    @AppStorage("tag.scale") private var tagScale = 1.0
    @AppStorage("tag.appearDelay") private var tagAppearDelay = 0.0
    @AppStorage("tag.disappearDelay") private var tagDisappearDelay = 0.0
    @AppStorage("tag.offsetX") private var tagOffsetX = 0.0
    @AppStorage("tag.offsetY") private var tagOffsetY = 0.0
    @AppStorage("tag.red") private var tagRed = 0.08
    @AppStorage("tag.green") private var tagGreen = 0.08
    @AppStorage("tag.blue") private var tagBlue = 0.09
    @AppStorage("tag.alpha") private var tagAlpha = 0.85
    @AppStorage("tag.textRed") private var tagTextRed = 1.0
    @AppStorage("tag.textGreen") private var tagTextGreen = 1.0
    @AppStorage("tag.textBlue") private var tagTextBlue = 1.0
    @AppStorage("tag.textAlpha") private var tagTextAlpha = 1.0

    private var configuration: TagConfiguration {
        TagConfiguration(
            position: TagPosition(rawValue: tagPosition) ?? .bottomCenter,
            label: TagLabel(rawValue: tagLabel) ?? .appName,
            overlap: tagOverlap,
            scale: tagScale,
            appearDelay: tagAppearDelay,
            disappearDelay: tagDisappearDelay,
            offsetX: tagOffsetX,
            offsetY: tagOffsetY,
            red: tagRed,
            green: tagGreen,
            blue: tagBlue,
            alpha: tagAlpha,
            textRed: tagTextRed,
            textGreen: tagTextGreen,
            textBlue: tagTextBlue,
            textAlpha: tagTextAlpha)
    }

    private var backgroundColor: Binding<Color> {
        Binding(
            get: {
                Color(.sRGB, red: tagRed, green: tagGreen, blue: tagBlue, opacity: tagAlpha)
            },
            set: { newValue in
                guard let color = NSColor(newValue).usingColorSpace(.deviceRGB) else { return }
                tagRed = color.redComponent
                tagGreen = color.greenComponent
                tagBlue = color.blueComponent
                tagAlpha = color.alphaComponent
            })
    }

    private var textColor: Binding<Color> {
        Binding(
            get: {
                Color(
                    .sRGB,
                    red: tagTextRed,
                    green: tagTextGreen,
                    blue: tagTextBlue,
                    opacity: tagTextAlpha)
            },
            set: { newValue in
                guard let color = NSColor(newValue).usingColorSpace(.deviceRGB) else { return }
                tagTextRed = color.redComponent
                tagTextGreen = color.greenComponent
                tagTextBlue = color.blueComponent
                tagTextAlpha = color.alphaComponent
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: probe.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(probe.isTrusted ? .green : .orange)
                Text(probe.status)
                Spacer()
            }

            Text("Edge overlap is 0% outside, 50% straddling, and 100% inside the window. Fine offset moves the tag from that position.")
                .foregroundStyle(.secondary)

            GroupBox("Tag") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Position")
                        Picker("Position", selection: $tagPosition) {
                            ForEach(TagPosition.allCases) { position in
                                Text(position.title).tag(position.rawValue)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Label")
                        Picker("Label", selection: $tagLabel) {
                            ForEach(TagLabel.allCases) { label in
                                Text(label.title).tag(label.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    GridRow {
                        Text("Edge overlap")
                        HStack {
                            Slider(value: $tagOverlap, in: 0...1)
                            Text(tagOverlap, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    GridRow {
                        Text("Size")
                        HStack {
                            Slider(value: $tagScale, in: 0.7...1.5)
                            Text(tagScale, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    GridRow {
                        Text("Appear delay")
                        HStack {
                            Slider(value: $tagAppearDelay, in: 0...0.5, step: 0.01)
                            Text("\(Int(tagAppearDelay * 1_000)) ms")
                                .monospacedDigit()
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                    GridRow {
                        Text("Disappear delay")
                        HStack {
                            Slider(value: $tagDisappearDelay, in: 0...0.5, step: 0.01)
                            Text("\(Int(tagDisappearDelay * 1_000)) ms")
                                .monospacedDigit()
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                    GridRow {
                        Text("Fine offset")
                        VStack {
                            HStack {
                                Text("X").frame(width: 12)
                                Slider(value: $tagOffsetX, in: -80...80, step: 1)
                                Text("\(Int(tagOffsetX)) pt")
                                    .monospacedDigit()
                                    .frame(width: 48, alignment: .trailing)
                            }
                            HStack {
                                Text("Y").frame(width: 12)
                                Slider(value: $tagOffsetY, in: -80...80, step: 1)
                                Text("\(Int(tagOffsetY)) pt")
                                    .monospacedDigit()
                                    .frame(width: 48, alignment: .trailing)
                            }
                        }
                    }
                    GridRow {
                        Text("Colors")
                        HStack(spacing: 16) {
                            ColorPicker("Background", selection: backgroundColor, supportsOpacity: true)
                            ColorPicker("Text", selection: textColor, supportsOpacity: true)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: 560)

            HStack {
                if !probe.isTrusted {
                    Button("Grant Accessibility Access", action: probe.requestAccess)
                }
                Button("Open Mission Control", action: probe.openMissionControl)
                    .disabled(!probe.isTrusted)
                Button("Copy Diagnostic Report", action: probe.copyReport)
                    .disabled(probe.report.isEmpty)
            }

            Group {
                if probe.report.isEmpty {
                    ContentUnavailableView(
                        "No Mission Control Capture Yet",
                        systemImage: "rectangle.3.group",
                        description: Text("Open Mission Control after granting Accessibility access."))
                } else {
                    ScrollView {
                        Text(probe.report)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .frame(minWidth: 720, minHeight: 780)
        .task(id: configuration) {
            while !Task.isCancelled {
                let delay = probe.poll(configuration: configuration)
                try? await Task.sleep(for: .milliseconds(delay))
            }
        }
    }
}

#Preview {
    ContentView()
}
