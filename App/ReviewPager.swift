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
        images = images.filter { wanted.contains($0.key) }; failed.formIntersection(wanted)
        for id in ids.prefix(3) where images[id] == nil && tasks[id] == nil {
            let token = UUID(); tokens[id] = token; failed.remove(id)
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
    @StateObject private var cache = ReviewImageCache()
    private var window: [String] { [current,next,previous].compactMap { $0 } }
    var body: some View {
        NativeReviewPager(current:current,previous:previous,next:next,video:video,images:cache.images,failed:cache.failed,step:step,stage:stage)
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
    func makeUIView(context: Context) -> ReviewScrollView { ReviewScrollView() }
    func updateUIView(_ view: ReviewScrollView,context: Context) {
        view.configure(current:current,previous:previous,next:next,video:video,images:images,failed:failed,step:step,stage:stage)
    }
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
private final class ReviewScrollView: UIView, UIGestureRecognizerDelegate {
    private let cards = (0..<3).map { _ in UIImageView() }
    private let notes = (0..<3).map { _ in UILabel() }
    private let badge = UILabel()
    private var currentID = ""
    private var previousID: String?
    private var generation = 0
    private var animating = false
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
        pan = UIPanGestureRecognizer(target:self,action:#selector(drag(_:))); pan.delegate = self; addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(current: String,previous: String?,next: String?,video: Bool,images: [String:UIImage],failed: Set<String>,step: @escaping (Int)->Void,stage: @escaping ()->Void) {
        self.step = step; self.stage = stage; previousID = previous
        if currentID != current {
            generation += 1; currentID = current; animating = false
            cards[1].layer.removeAllAnimations(); cards[1].transform = .identity; badge.alpha = 0
            cards[0].alpha = 0; cards[2].alpha = 0
        }
        accessibilityLabel = L.t(video ? "视频" : "照片")
        for (i,id) in [previous,Optional(current),next].enumerated() {
            cards[i].image = id.flatMap { images[$0] }
            if let id { notes[i].text = cards[i].image == nil ? L.t(failed.contains(id) ? "图片暂不可用，请点查看清晰" : "正在读取清晰照片…") : nil }
            else { notes[i].text = L.t("这一组看完了") }
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for i in cards.indices {
            // Bounds/centre avoid changing the transformed card's frame during a drag.
            cards[i].bounds = bounds; cards[i].center = CGPoint(x:bounds.midX,y:bounds.midY)
            notes[i].frame = bounds.insetBy(dx:16,dy:16)
        }
        badge.frame = CGRect(x:max(0,(bounds.width-120)/2),y:20,width:120,height:38)
    }
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pan else { return super.gestureRecognizerShouldBegin(recognizer) }
        let v = pan.velocity(in:self)
        return !animating && (abs(v.x) > abs(v.y) || v.y < 0)
    }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        let p = recognizer.translation(in:self), v = recognizer.velocity(in:self)
        switch recognizer.state {
        case .changed:
            cards[0].alpha = p.x > 0 && previousID != nil ? 1 : 0; cards[2].alpha = cards[0].alpha == 0 ? 1 : 0
            let x = p.x > 0 && previousID == nil ? p.x*0.25 : p.x
            cards[1].transform = CGAffineTransform(translationX:x,y:p.y*0.65).rotated(by:x/max(1,bounds.width)*0.12)
            badge.alpha = p.y < -40 && abs(p.y) > abs(p.x) ? min(1,(-p.y-40)/60) : 0
        case .ended:
            finish(ReviewSwipe.resolve(x:p.x,y:p.y,vx:v.x,vy:v.y,width:bounds.width,hasPrevious:previousID != nil))
        case .cancelled,.failed: finish(.cancel)
        default: break
        }
    }
    private func finish(_ action: ReviewSwipe) {
        if action == .cancel {
            UIView.animate(withDuration:0.3,delay:0,usingSpringWithDamping:0.78,initialSpringVelocity:0,options:[.allowUserInteraction,.beginFromCurrentState]) { self.cards[1].transform = .identity; self.badge.alpha = 0 }
            return
        }
        animating = true; let ticket = generation
        let x: CGFloat = action == .previous ? bounds.width*1.25 : (action == .next ? -bounds.width*1.25 : 0)
        let y: CGFloat = action == .stage ? -bounds.height*1.15 : 0
        UIView.animate(withDuration:0.18,delay:0,options:[.curveEaseOut,.beginFromCurrentState]) {
            self.cards[1].transform = CGAffineTransform(translationX:x,y:y).rotated(by:x/max(1,self.bounds.width)*0.12)
        } completion: { [weak self] _ in
            guard let self,self.generation == ticket else { return }
            if action == .stage { self.stage() } else { self.step(action == .next ? 1 : -1) }
        }
    }
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard !animating else { return false }
        if direction == .left { finish(.next); return true }
        if direction == .right, previousID != nil { finish(.previous); return true }
        if direction == .up { finish(.stage); return true }
        return false
    }
}
