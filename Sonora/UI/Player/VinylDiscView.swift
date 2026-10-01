//
//  VinylDiscView.swift
//  Sonora
//
//  The Now Playing cover drawn as a vinyl record that turns while music
//  plays and stops where it is when paused.
//
//  The spin is a Core Animation rotation, not a SwiftUI timer. Core Animation
//  runs it in the system's render server, so the app itself does no work per
//  frame - the cheapest way to animate something forever. Pausing freezes the
//  layer's clock (speed 0) rather than removing the animation, so the record
//  picks up again from the same angle instead of snapping back to the start.
//

import SwiftUI
import UIKit

struct VinylDiscView: UIViewRepresentable {
    let artworkKey: String?
    let spinning: Bool
    /// Label colour used when the track has no cover.
    let labelColor: UIColor

    func makeUIView(context: Context) -> VinylDiscUIView {
        VinylDiscUIView()
    }

    func updateUIView(_ view: VinylDiscUIView, context: Context) {
        view.labelColor = labelColor
        view.setArtworkKey(artworkKey)
        view.setSpinning(spinning)
    }
}

final class VinylDiscUIView: UIView {

    /// Seconds per turn. A real record does one every 1.8 s, which is far too
    /// busy to look at; this is a calm, readable pace.
    private static let period: CFTimeInterval = 10

    /// Everything inside rotates together.
    private let disc = CALayer()
    private let record = CAShapeLayer()
    private let grooves = CAShapeLayer()
    private let art = CALayer()
    private let labelRing = CAShapeLayer()
    private let spindle = CAShapeLayer()
    /// Fixed light reflection. It does not turn, which is what makes the
    /// black part of the record visibly spin.
    private let sheen = CAGradientLayer()
    private let sheenMask = CAShapeLayer()

    private var key: String?
    private var hasImage = false
    private var wantsSpin = false
    private var loadTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    var labelColor: UIColor = .systemOrange {
        didSet { if !hasImage { art.backgroundColor = labelColor.cgColor } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        loadTask?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    private func setUp() {
        isUserInteractionEnabled = false
        backgroundColor = .clear

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 22
        layer.shadowOffset = CGSize(width: 0, height: 12)

        record.fillColor = UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1).cgColor
        grooves.fillColor = UIColor.clear.cgColor
        grooves.strokeColor = UIColor(white: 1, alpha: 0.055).cgColor
        grooves.lineWidth = 0.6

        art.masksToBounds = true
        art.contentsGravity = .resizeAspectFill
        art.backgroundColor = labelColor.cgColor

        labelRing.fillColor = UIColor.clear.cgColor
        labelRing.strokeColor = UIColor(white: 0, alpha: 0.35).cgColor
        labelRing.lineWidth = 1.5

        spindle.fillColor = UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1).cgColor
        spindle.strokeColor = UIColor(white: 1, alpha: 0.18).cgColor
        spindle.lineWidth = 1

        sheen.type = .conic
        sheen.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)
        let glint = UIColor(white: 1, alpha: 0.10).cgColor
        let clear = UIColor(white: 1, alpha: 0).cgColor
        sheen.colors = [clear, glint, clear, clear, glint, clear, clear]
        sheen.locations = [0, 0.08, 0.2, 0.5, 0.58, 0.7, 1]
        sheenMask.fillRule = .evenOdd
        sheen.mask = sheenMask

        disc.addSublayer(record)
        disc.addSublayer(grooves)
        disc.addSublayer(art)
        disc.addSublayer(labelRing)
        disc.addSublayer(spindle)
        layer.addSublayer(disc)
        layer.addSublayer(sheen)

        // Core Animation can drop animations while the app is in the
        // background; put the spin back when we return.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applySpin() }
            }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let square = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                            width: side, height: side)
        let r = side / 2
        let local = CGRect(origin: .zero, size: square.size)
        let centre = CGPoint(x: r, y: r)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Changing bounds/position does not disturb the rotation transform.
        disc.bounds = local
        disc.position = CGPoint(x: square.midX, y: square.midY)
        record.frame = local
        record.path = UIBezierPath(ovalIn: local).cgPath

        let groovePath = UIBezierPath()
        var radius = r * 0.97
        let step = max(2.2, r * 0.018)
        while radius > r * 0.70 {
            groovePath.append(UIBezierPath(arcCenter: centre, radius: radius,
                                           startAngle: 0, endAngle: .pi * 2, clockwise: true))
            radius -= step
        }
        grooves.frame = local
        grooves.path = groovePath.cgPath

        let labelR = r * 0.66
        art.frame = CGRect(x: r - labelR, y: r - labelR, width: labelR * 2, height: labelR * 2)
        art.cornerRadius = labelR

        labelRing.frame = local
        labelRing.path = UIBezierPath(arcCenter: centre, radius: labelR,
                                      startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath

        let holeR = max(4, r * 0.045)
        spindle.frame = local
        spindle.path = UIBezierPath(ovalIn: CGRect(x: r - holeR, y: r - holeR,
                                                   width: holeR * 2, height: holeR * 2)).cgPath

        sheen.frame = square
        let ring = UIBezierPath(ovalIn: local)
        ring.append(UIBezierPath(ovalIn: local.insetBy(dx: r - labelR, dy: r - labelR)))
        sheenMask.frame = local
        sheenMask.path = ring.cgPath

        layer.shadowPath = UIBezierPath(ovalIn: square).cgPath
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applySpin() }
    }

    // MARK: Artwork

    func setArtworkKey(_ newKey: String?) {
        guard newKey != key else { return }
        key = newKey
        loadTask?.cancel()

        guard let newKey else {
            showImage(nil)
            return
        }
        loadTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                ArtworkStore.shared.image(forKey: newKey)
            }.value
            guard !Task.isCancelled, let self, self.key == newKey else { return }
            self.showImage(image)
        }
    }

    private func showImage(_ image: UIImage?) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.3
        art.add(fade, forKey: "contents")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let cg = image?.cgImage {
            art.contents = cg
            art.backgroundColor = UIColor.black.cgColor
            hasImage = true
        } else {
            art.contents = nil
            art.backgroundColor = labelColor.cgColor
            hasImage = false
        }
        CATransaction.commit()
    }

    // MARK: Spin

    func setSpinning(_ spinning: Bool) {
        wantsSpin = spinning
        applySpin()
    }

    private func applySpin() {
        if disc.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = Self.period
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            disc.add(spin, forKey: "spin")
        }

        let run = wantsSpin && !UIAccessibility.isReduceMotionEnabled
        if run && disc.speed == 0 {
            // Resume from the angle it stopped at.
            let pausedAt = disc.timeOffset
            disc.speed = 1
            disc.timeOffset = 0
            disc.beginTime = 0
            disc.beginTime = disc.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        } else if !run && disc.speed != 0 {
            // Freeze the clock where it is.
            let now = disc.convertTime(CACurrentMediaTime(), from: nil)
            disc.speed = 0
            disc.timeOffset = now
        }
    }
}
