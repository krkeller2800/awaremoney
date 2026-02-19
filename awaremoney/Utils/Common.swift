//
//  GradientAdButtonStyle.swift
//  awaremoney
//
//  Created by Karl Keller on 2/16/26.
//
import UIKit
import SwiftUI
import SwiftData
import Foundation

struct GradientAdButtonStyle: ButtonStyle {
    // Access the environment to check if the view hierarchy is currently enabled
    @Environment(\.isEnabled) private var isEnabled
    
    var startColor: Color = .cyan
    var endColor: Color = .indigo
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline).bold()
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [startColor, endColor]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: endColor.opacity(0.4), radius: 10, x: 0, y: 10)
            // Apply dimming effect (e.g., reduce opacity) when disabled
            .opacity(isEnabled ? 1.0 : 0.5)
            // Apply a slight scaling effect when pressed for better user feedback
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
struct Toolbarbutton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.trigger()
        } label: {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color.blue)
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain) // ensures toolbar doesn't re-style it
        .contentShape(Capsule())
        .frame(width:100,alignment: .leading)
    }
}
public struct PlanMenuLabel: View {
    public let title: String
    public let backgroundColor: Color
    public let foregroundColor: Color
    public let titleFont: Font

    public init(title: String = "Plan", backgroundColor: Color = .blue, foregroundColor: Color = .white, titleFont: Font = .callout) {
        self.title = title
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.titleFont = titleFont
    }

    public var body: some View {
        Text(title)
            .font(titleFont).bold()
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(backgroundColor)
            }
    }
}

public struct PlanToolbarButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    public var backgroundColor: Color
    public var foregroundColor: Color
    public var titleFont: Font
    public var fixedWidth: CGFloat?

    public init(backgroundColor: Color = .blue,
                foregroundColor: Color = .white,
                titleFont: Font = .callout,
                fixedWidth: CGFloat? = nil) {
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.titleFont = titleFont
        self.fixedWidth = fixedWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.trigger()
        } label: {
            configuration.label
                .font(titleFont.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(backgroundColor)
                }
        }
        .buttonStyle(.plain) // ensure toolbar doesn't re-style it
        .contentShape(Capsule())
        .frame(width: fixedWidth, alignment: .leading)
        .opacity(isEnabled ? 1.0 : 0.5)
    }
}

public struct PlanToolbarButton: View {
    public let title: String
    public let backgroundColor: Color
    public let foregroundColor: Color
    public let titleFont: Font
    public let fixedWidth: CGFloat?
    public let action: () -> Void

    public init(_ title: String,
                backgroundColor: Color = .blue,
                foregroundColor: Color = .white,
                titleFont: Font = .callout,
                fixedWidth: CGFloat? = nil,
                action: @escaping () -> Void) {
        self.title = title
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.titleFont = titleFont
        self.fixedWidth = fixedWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(PlanToolbarButtonStyle(backgroundColor: backgroundColor,
                                            foregroundColor: foregroundColor,
                                            titleFont: titleFont,
                                            fixedWidth: fixedWidth))
    }
}

