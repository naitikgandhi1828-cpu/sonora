//
//  AmbientGlowView.swift
//  Sonora
//
//  Soft colour glows taken from the album art, drifting slowly behind the
//  Now Playing screen.
//
//  Built the same way as the vinyl record: plain Core Animation layers with
//  long repeating animations. Core Animation runs those in the system's
//  render server, so the app does no work per frame - far cheaper than a
//  SwiftUI timeline or a live blur. Each glow is a radial gradient that
//  fades to transparent, so it looks blurred without any blur filter.
//
//  When `drifting` is false (paused, Battery Saver, Reduce Motion) the glows
//  freeze exactly where they are and cost nothing.
//

import SwiftUI
import UIKit

struct AmbientGlowView: UIViewRepresentable {
    let colours: [Color]
    let drifting: Bool
    /// Light themes get slightly fainter glows so text stays readable.
    let isDarkTheme: Bool

    func makeUIView(context: Context) -> AmbientGlowUIView {
        AmbientGlowUIView()
    }

    func updateUIView(_ view: AmbientGlowUIView, context: Context) {
        view.setColours(colours.map { UIColor($0) }, strength: isDarkTheme ? 0.55 : 0.42)
        view.setDrifting(drifting)
    }
}

final class AmbientGlowUIView: UIView {

    /// Where each glow sits, as a fraction of the view.
    private static let anchors: [CGPoint] = [CGPoint(x: 0.22, y: 0.20),
                                             CGPoint(x: 0.80, y: 0.46),
                                             CGPoint(x: 0.32, y: 0.84)]
    /// Different, unrelated periods so the motion never visibly repeats.
    private static let periodsX: [CFTimeInterval] = [19, 23, 29]
    private static let periodsY: [CFTimeInterval] = [17, 26, 21]

    private let field = CALayer()
    private var blobs: [CAGradientLayer] = []
    private var wantsDrift = false
    private var laidOutSize: CGSize = .zero
    private var lastColours: [UIColor] = []
    private var lastStrength: CGFloat = -1
    private var foregroundObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    private func setUp() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = true

        for _ in Self.anchors {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
            field.addSublayer(blob)
            blobs.append(blob)
        }
        layer.addSublayer(field)

        // Core Animation may drop animations while the app is in the
        // background; put them back when we return.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.installAnimations(force: false) }
            }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.frame = bounds
        let side = max(bounds.width, bounds.height) * 0.95
        for (i, blob) in blobs.enumerated() {
            let anchor = Self.anchors[i % Self.anchors.count]
            blob.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            blob.position = CGPoint(x: bounds.width * anchor.x, y: bounds.height * anchor.y)
        }
        CATransaction.commit()

        // Drift distances depend on the size, so rebuild them on a resize.
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            installAnimations(force: true)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { installAnimations(force: false) }
    }

    // MARK: Colours

    func setColours(_ colours: [UIColor], strength: CGFloat) {
        guard !colours.isEmpty else { return }
        guard colours != lastColours || strength != lastStrength else { return }
        lastColours = colours
        lastStrength = strength

        CATransaction.begin()
        // A slow crossfade when the track (and so the palette) changes.
        CATransaction.setAnimationDuration(0.9)
        for (i, blob) in blobs.enumerated() {
            let colour = colours[i % colours.count]
            blob.colors = [colour.withAlphaComponent(strength).cgColor,
                           colour.withAlphaComponent(strength * 0.45).cgColor,
                           colour.withAlphaComponent(0).cgColor]
            blob.locations = [0, 0.45, 1]
        }
        CATransaction.commit()
    }

    // MARK: Drift

    func setDrifting(_ drifting: Bool) {
        wantsDrift = drifting
        installAnimations(force: false)
    }

    private func installAnimations(force: Bool) {
        guard laidOutSize.width > 0 else { return }
        let dx = laidOutSize.width * 0.20
        let dy = laidOutSize.height * 0.10

        for (i, blob) in blobs.enumerated() {
            if force || blob.animation(forKey: "driftX") == nil {
                blob.add(drift("transform.translation.x",
                               amount: i % 2 == 0 ? dx : -dx,
                               period: Self.periodsX[i % Self.periodsX.count]), forKey: "driftX")
            }
            if force || blob.animation(forKey: "driftY") == nil {
                blob.add(drift("transform.translation.y",
                               amount: i == 1 ? -dy : dy,
                               period: Self.periodsY[i % Self.periodsY.count]), forKey: "driftY")
            }
            if force || blob.animation(forKey: "breathe") == nil {
                let breathe = CABasicAnimation(keyPath: "transform.scale")
                breathe.fromValue = 0.92
                breathe.toValue = 1.10
                breathe.duration = Self.periodsY[(i + 1) % Self.periodsY.count]
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                breathe.isRemovedOnCompletion = false
                blob.add(breathe, forKey: "breathe")
            }
        }
        applyClock()
    }

    private func drift(_ keyPath: String, amount: CGFloat, period: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = -amount
        a.toValue = amount
        a.duration = period
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        return a
    }

    /// Runs or freezes every glow at once by pausing the shared clock, so
    /// nothing jumps when the music pauses and resumes.
    private func applyClock() {
        let run = wantsDrift && !UIAccessibility.isReduceMotionEnabled
        if run && field.speed == 0 {
            let pausedAt = field.timeOffset
            field.speed = 1
            field.timeOffset = 0
            field.beginTime = 0
            field.beginTime = field.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        } else if !run && field.speed != 0 {
            let now = field.convertTime(CACurrentMediaTime(), from: nil)
            field.speed = 0
            field.timeOffset = now
        }
    }
}
