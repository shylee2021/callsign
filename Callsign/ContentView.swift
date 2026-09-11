//
//  ContentView.swift
//  Callsign
//
//  Created by shylee on 8/25/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var probe = MissionControlProbe()
    @AppStorage("tag.position") private var tagPosition = TagConfiguration.default.position.rawValue
    @AppStorage("tag.label") private var tagLabel = TagConfiguration.default.label.rawValue
    @AppStorage("tag.overlap") private var tagOverlap = TagConfiguration.default.overlap
    @AppStorage("tag.scale") private var tagScale = TagConfiguration.default.scale
    @AppStorage("tag.appearDelay") private var tagAppearDelay = TagConfiguration.default.appearDelay
    @AppStorage("tag.disappearDelay") private var tagDisappearDelay = TagConfiguration.default.disappearDelay
    @AppStorage("tag.offsetX") private var tagOffsetX = TagConfiguration.default.offsetX
    @AppStorage("tag.offsetY") private var tagOffsetY = TagConfiguration.default.offsetY
    @AppStorage("tag.red") private var tagRed = TagConfiguration.default.red
    @AppStorage("tag.green") private var tagGreen = TagConfiguration.default.green
    @AppStorage("tag.blue") private var tagBlue = TagConfiguration.default.blue
    @AppStorage("tag.alpha") private var tagAlpha = TagConfiguration.default.alpha
    @AppStorage("tag.textRed") private var tagTextRed = TagConfiguration.default.textRed
    @AppStorage("tag.textGreen") private var tagTextGreen = TagConfiguration.default.textGreen
    @AppStorage("tag.textBlue") private var tagTextBlue = TagConfiguration.default.textBlue
    @AppStorage("tag.textAlpha") private var tagTextAlpha = TagConfiguration.default.textAlpha

    private var configuration: TagConfiguration {
        TagConfiguration(
            position: TagPosition(rawValue: tagPosition) ?? TagConfiguration.default.position,
            label: TagLabel(rawValue: tagLabel) ?? TagConfiguration.default.label,
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
        colorBinding(red: $tagRed, green: $tagGreen, blue: $tagBlue, alpha: $tagAlpha)
    }

    private var textColor: Binding<Color> {
        colorBinding(red: $tagTextRed, green: $tagTextGreen, blue: $tagTextBlue, alpha: $tagTextAlpha)
    }

    private func colorBinding(
        red: Binding<Double>, green: Binding<Double>, blue: Binding<Double>, alpha: Binding<Double>
    ) -> Binding<Color> {
        Binding(
            get: {
                Color(.sRGB, red: red.wrappedValue, green: green.wrappedValue,
                      blue: blue.wrappedValue, opacity: alpha.wrappedValue)
            },
            set: { newValue in
                guard let color = NSColor(newValue).usingColorSpace(.deviceRGB) else { return }
                red.wrappedValue = color.redComponent
                green.wrappedValue = color.greenComponent
                blue.wrappedValue = color.blueComponent
                alpha.wrappedValue = color.alphaComponent
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
