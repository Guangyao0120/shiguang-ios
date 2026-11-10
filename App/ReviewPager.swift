import SwiftUI
import UIKit

// Keep only the visible photo and its two neighbours; never decode a whole album.
@MainActor
final class ReviewImageCache: ObservableObject {
    @Published private(set) var images: [String:UIImage] = [:]
    @Published private(set) var failed: Set<String> = []
    private var tasks: [String:Task<Void,Never>] = [:]
    private var tokens: [String:UUID] = [:]
    private let loader: (String) async -> UIImage?
    init(loader: @escaping (String) async -> UIImage? = { id in
        guard !DesignPreview.enabled else { return nil }
        return await PhotoAccess.image(id:id,size:CGSize(width:2048,height:2048),highQuality:true)
    }) { self.loader = loader }
    func update(_ ids: [String]) {
        let wanted = Set(ids.prefix(3))
        for id in Array(tasks.keys) where !wanted.contains(id) {
            tasks.removeValue(forKey:id)?.cancel(); tokens.removeValue(forKey:id)
        }
        if images.keys.contains(where:{ !wanted.contains($0) }) { images = images.filter { wanted.contains($0.key) } }
        let remainingFailures = failed.intersection(wanted)
        if remainingFailures != failed { failed = remainingFailures }
        for id in ids.prefix(3) where images[id] == nil && tasks[id] == nil {
            let token = UUID(); tokens[id] = token
            if failed.contains(id) { failed.remove(id) }
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                let image = await loader(id)
                guard !Task.isCancelled, tokens[id] == token else { return }
                guard let image, image.cgImage != nil || image.ciImage != nil else {
                    tasks.removeValue(forKey:id); tokens.removeValue(forKey:id); failed.insert(id); return
                }
                // UIKit uses its background preparation queue, so decoding is not
                // deferred to the first frame of the horizontal animation.
                let prepared = await image.byPreparingForDisplay()
                guard !Task.isCancelled, tokens[id] == token else { return }
                tasks.removeValue(forKey:id); tokens.removeValue(forKey:id)
                images[id] = prepared ?? image
            }
        }
    }
    func clear() {
        tasks.values.forEach { $0.cancel() }; tasks = [:]; tokens = [:]; images = [:]; failed = []
    }
}

struct ReviewPager: View {
    let current: String
    let previous: String?
    let next: String?
    let video: Bool
    let step: (Int)->Void
    let stage: ()->Void
    var command: ReviewMotionRequest? = nil
    @StateObject private var cache = ReviewImageCache()
    private var window: [String] { [current,next,previous].compactMap { $0 } }
    var body: some View {
        NativeReviewPager(current:current,previous:previous,next:next,video:video,images:cache.images,failed:cache.failed,step:step,stage:stage,command:command)
            .onAppear { cache.update(window) }
            .onChange(of:window) { _,ids in cache.update(ids) }
            .onDisappear { cache.clear() }
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in
                cache.clear(); cache.update([current])
            }
    }
}

private struct NativeReviewPager: UIViewRepresentable {
    let current: String
    let previous: String?
    let next: String?
    let video: Bool
    let images: [String:UIImage]
    let failed: Set<String>
    let step: (Int)->Void
    let stage: ()->Void
    let command: ReviewMotionRequest?
    func makeUIView(context: Context) -> ReviewScrollView { ReviewScrollView() }
    func updateUIView(_ view: ReviewScrollView,context: Context) {
        view.configure(current:current,previous:previous,next:next,video:video,images:images,failed:failed,step:step,stage:stage)
        if let command { view.perform(command) }
    }
}

struct ReviewMotionRequest {
    let id = UUID()
    let action: ReviewSwipe
}

enum ReviewSwipe: Equatable {
    case previous, next, stage, cancel
    static func resolve(x: CGFloat,y: CGFloat,vx: CGFloat,vy: CGFloat,width: CGFloat,hasPrevious: Bool) -> ReviewSwipe {
        let projectedX = x + vx*0.12, projectedY = y + vy*0.12
        if projectedY < -100 && abs(projectedY) > abs(projectedX)*1.15 { return .stage }
        let threshold = max(72,width*0.23)
        if abs(projectedX) > abs(projectedY) && projectedX < -threshold { return .next }
        if abs(projectedX) > abs(projectedY) && projectedX > threshold && hasPrevious { return .previous }
        return .cancel
    }
}

@MainActor
final class ReviewScrollView: UIView, UIGestureRecognizerDelegate {
    private var cards = (0..<3).map { _ in UIImageView() }
    private var notes = (0..<3).map { _ in UILabel() }
    private var cardIDs: [String?] = [nil,nil,nil]
    private let badge = UILabel()
    private let feedback = UIImpactFeedbackGenerator(style:.soft)
    private var currentID = ""
    private var previousID: String?
    private var generation = 0
    private var animating = false
    private var dragOrigin = CGPoint.zero
    private var verticalDrag = false
    private var animator: UIViewPropertyAnimator?
    private var animationToken = UUID()
    private var handledCommand: UUID?
    private var step: (Int)->Void = { _ in }
    private var stage: ()->Void = {}
    private var pan: UIPanGestureRecognizer!
    override init(frame: CGRect) {
        super.init(frame:frame)
        backgroundColor = UIColor(Palette.surface)
        accessibilityIdentifier = "review.photo"; isAccessibilityElement = true; accessibilityTraits = .image
        for i in [0,2,1] {
            cards[i].contentMode = .scaleAspectFit; cards[i].clipsToBounds = true
            cards[i].backgroundColor = UIColor(Palette.surface)
            cards[i].layer.cornerRadius = 20
            notes[i].textAlignment = .center; notes[i].font = .preferredFont(forTextStyle:.subheadline)
            notes[i].textColor = .secondaryLabel; notes[i].numberOfLines = 2
            cards[i].addSubview(notes[i]); addSubview(cards[i])
        }
        badge.text = L.t("放入待删"); badge.textColor = .white; badge.backgroundColor = .systemRed
        badge.textAlignment = .center; badge.layer.cornerRadius = 12; badge.clipsToBounds = true; badge.alpha = 0
        cards[1].addSubview(badge)
        cards[0].alpha = 0; cards[2].alpha = 0
        pan = UIPanGestureRecognizer(target:self,action:#selector(drag(_:))); pan.delegate = self; addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(current: String,previous: String?,next: String?,video: Bool,images: [String:UIImage],failed: Set<String>,step: @escaping (Int)->Void,stage: @escaping ()->Void) {
        self.step = step; self.stage = stage; previousID = previous
        let changed = currentID != current
        if changed {
            generation += 1; animationToken = UUID()
            animator?.stopAnimation(true); animator = nil
            // Promote the already visible neighbour itself. Replacing the image
            // in the outgoing middle view creates a flash at the hand-off.
            if let incoming = cardIDs.firstIndex(where:{ $0 == current }), incoming != 1 {
                cards.swapAt(1,incoming); notes.swapAt(1,incoming); cardIDs.swapAt(1,incoming)
            }
            currentID = current; animating = false; dragOrigin = .zero
            UIView.performWithoutAnimation {
                for i in cards.indices {
                    cards[i].layer.removeAllAnimations()
                    cards[i].transform = .identity; cards[i].alpha = i == 1 ? 1 : 0
                }
                for i in [0,2,1] { self.bringSubviewToFront(self.cards[i]) }
                self.cards[1].addSubview(self.badge); self.badge.alpha = 0
            }
        }
        accessibilityLabel = L.t(video ? "视频" : "照片")
        accessibilityValue = images[current] == nil ? L.t("照片尚未就绪") : L.t("清晰照片已就绪")
        for (i,id) in [previous,Optional(current),next].enumerated() {
            // Keep the destination stable if a library update arrives while the
            // outgoing card is still moving. Bind the new window at hand-off.
            if animating && !changed && cardIDs[i] != id { continue }
            let image = id.flatMap { images[$0] }
            if cards[i].image !== image { cards[i].image = image }
            cardIDs[i] = id
            let text: String?
            if let id { text = image == nil ? L.t(failed.contains(id) ? "图片暂不可用，请点查看清晰" : "正在读取清晰照片…") : nil }
            else { text = L.t("这一组看完了") }
            if notes[i].text != text { notes[i].text = text }
        }
        setNeedsLayout()
    }
    func perform(_ command: ReviewMotionRequest) {
        guard handledCommand != command.id else { return }
        handledCommand = command.id
        guard !animating, pan.state != .began, pan.state != .changed else { return }
        if command.action == .previous && previousID == nil { return }
        finish(command.action,velocity:.zero)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for i in cards.indices {
            cards[i].bounds = bounds; cards[i].center = CGPoint(x:bounds.midX,y:bounds.midY)
            notes[i].frame = bounds.insetBy(dx:16,dy:16)
        }
        badge.frame = CGRect(x:max(0,(bounds.width-120)/2),y:20,width:120,height:38)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            generation += 1; animationToken = UUID()
            animator?.stopAnimation(true); animator = nil; animating = false
        }
    }
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pan else { return super.gestureRecognizerShouldBegin(recognizer) }
        let v = pan.velocity(in:self)
        return !animating && (abs(v.x) > abs(v.y) || v.y < 0)
    }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        let raw = recognizer.translation(in:self), velocity = recognizer.velocity(in:self)
        switch recognizer.state {
        case .began:
            let transform = cards[1].layer.presentation()?.affineTransform() ?? cards[1].transform
            animationToken = UUID(); animator?.stopAnimation(true); animator = nil
            cards[1].layer.removeAllAnimations(); cards[1].transform = transform
            verticalDrag = velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
            dragOrigin = CGPoint(x:transform.tx,y:transform.ty/(verticalDrag ? 0.9 : 0.12))
            feedback.prepare()
        case .changed:
            let p = CGPoint(x:raw.x+dragOrigin.x,y:raw.y+dragOrigin.y)
            let x = verticalDrag ? p.x*0.15 : (p.x > 0 && previousID == nil ? p.x*0.25 : p.x)
            let y = p.y*(verticalDrag ? 0.9 : 0.12)
            let rotation = UIAccessibility.isReduceMotionEnabled ? 0 : x/max(1,bounds.width)*(verticalDrag ? 0.04 : 0.12)
            cards[1].transform = CGAffineTransform(translationX:x,y:y).rotated(by:rotation)
            reveal(previous:!verticalDrag && p.x > 0 && previousID != nil,
                   progress:min(1,verticalDrag ? max(0,-p.y)/max(100,bounds.height*0.5) : abs(p.x)/max(1,bounds.width)))
            badge.alpha = verticalDrag && p.y < -35 ? min(1,(-p.y-35)/65) : 0
        case .ended:
            let p = CGPoint(x:raw.x+dragOrigin.x,y:raw.y+dragOrigin.y)
            let action = ReviewSwipe.resolve(x:p.x*(verticalDrag ? 0.15 : 1),y:p.y*(verticalDrag ? 1 : 0.12),
                vx:velocity.x*(verticalDrag ? 0.15 : 1),vy:velocity.y*(verticalDrag ? 1 : 0.12),
                width:bounds.width,hasPrevious:previousID != nil)
            finish(action,velocity:velocity)
        case .cancelled,.failed: finish(.cancel,velocity:.zero)
        default: break
        }
    }
    private func reveal(previous: Bool,progress: CGFloat) {
        let behind = previous ? 0 : 2
        cards[previous ? 2 : 0].alpha = 0
        cards[behind].alpha = 1
        if UIAccessibility.isReduceMotionEnabled { cards[behind].transform = .identity }
        else {
            let scale = 0.965+0.035*progress
            cards[behind].transform = CGAffineTransform(translationX:0,y:12*(1-progress)).scaledBy(x:scale,y:scale)
        }
    }
    private func finish(_ action: ReviewSwipe,velocity: CGPoint) {
        animationToken = UUID()
        let token = animationToken
        if let animator {
            let presentation = cards.map { ($0.layer.presentation()?.affineTransform() ?? $0.transform, $0.layer.presentation()?.opacity ?? Float($0.alpha)) }
            animator.stopAnimation(true)
            UIView.performWithoutAnimation {
                for i in self.cards.indices { self.cards[i].transform = presentation[i].0; self.cards[i].alpha = CGFloat(presentation[i].1) }
            }
        }
        if action == .cancel {
            let settle = UIViewPropertyAnimator(duration:UIAccessibility.isReduceMotionEnabled ? 0.16 : 0.3,dampingRatio:0.86)
            animator = settle
            settle.addAnimations {
                self.cards[1].transform = .identity; self.cards[1].alpha = 1; self.badge.alpha = 0
                self.cards[0].alpha = 0; self.cards[2].alpha = 0
            }
            settle.addCompletion { [weak self] _ in
                guard let self,self.animationToken == token else { return }
                self.animator = nil; self.dragOrigin = .zero
            }
            settle.startAnimation()
            return
        }
        animating = true
        let ticket = generation
        let reduce = UIAccessibility.isReduceMotionEnabled
        let x: CGFloat = action == .previous ? bounds.width*1.25 : (action == .next ? -bounds.width*1.25 : 0)
        let y: CGFloat = action == .stage ? -bounds.height*1.1 : 0
        let offset = cards[1].transform
        let distance = action == .stage ? abs(y-offset.ty) : abs(x-offset.tx)
        let speed = max(900,abs(action == .stage ? velocity.y : velocity.x))
        let duration = reduce ? 0.16 : min(0.28,max(0.18,Double(distance/speed)))
        // Button, VoiceOver and pan share the same reveal and single commit.
        // Never enqueue PhotoKit or persistence work inside a gesture frame.
        let behind = action == .previous ? 0 : 2
        if cards[behind].alpha == 0 { reveal(previous:action == .previous,progress:0) }
        let departure = UIViewPropertyAnimator(duration:duration,curve:.easeOut)
        animator = departure
        departure.addAnimations {
            self.cards[1].transform = reduce ? self.cards[1].transform : CGAffineTransform(translationX:x,y:y).rotated(by:x/max(1,self.bounds.width)*0.12)
            self.cards[1].alpha = reduce || action == .stage ? 0 : 1
            self.cards[behind].transform = .identity
            self.badge.alpha = action == .stage && !reduce ? 1 : 0
        }
        departure.addCompletion { [weak self] position in
            guard let self,position == .end,self.generation == ticket,self.animationToken == token else { return }
            self.animator = nil
            if action == .stage { self.feedback.impactOccurred(intensity:0.65); self.stage() }
            else { self.step(action == .next ? 1 : -1) }
        }
        departure.startAnimation()
    }
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !animating else { return false }
        if direction == .left { finish(.next,velocity:.zero); return true }
        if direction == .right, previousID != nil { finish(.previous,velocity:.zero); return true }
        if direction == .up { finish(.stage,velocity:.zero); return true }
        return false
    }
}
