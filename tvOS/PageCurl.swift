import SwiftUI
import MetalKit
import QuartzCore

/// A page turned by hand, the way iBooks turned them on iPad.
///
/// The page being turned is a fine mesh wrapped around a moving cylinder: flat where it
/// still lies on the book, rolled where it lifts, and lying face-down beyond the roll —
/// the front of the page on one side, the next page printed on its back. Where it has
/// lifted, the page beneath is shaded, darkest close in under the roll.
///
/// It follows the thumb on the Siri Remote: `drag(to:)` while the thumb is down, then
/// `release` lets it fall over or settle back depending on how far and how fast it went.
/// Edge clicks use `play`, the same curl run by itself.
@MainActor
@Observable
final class PageCurl {
    /// The four pictures a turn is made of, each one page of the spread.
    struct Pages {
        /// What lies on the left and right of the book underneath the turning page.
        var left: CGImage
        var right: CGImage
        /// The turning page's front, and what's printed on its back.
        var front: CGImage
        var back: CGImage
    }

    /// Showing: the curl is drawn over the book until the turn lands or settles back.
    private(set) var isActive = false
    /// 0 lying flat where it started; 1 turned all the way over.
    private(set) var progress: CGFloat = 0
    /// Turning the right page leftward (forward), or the left page rightward.
    private(set) var forward = true
    /// Where on the page's edge it's held, 0 top to 1 bottom.
    private(set) var grip: CGFloat = 0.82

    @ObservationIgnored private(set) var pages: Pages?
    @ObservationIgnored var redraw: () -> Void = {}

    /// Where the thumb has carried the page. The page glides toward it rather than
    /// jumping to each touch reading, which arrive in coarse steps from the remote.
    @ObservationIgnored private var target: CGFloat = 0
    /// How fast the page is moving, in turns per second — carried into the fall.
    @ObservationIgnored private var velocity: CGFloat = 0
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var flight: Flight?

    /// A turn finishing, or settling back, on its own.
    private struct Flight {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval
        var duration: CFTimeInterval
        /// Slopes at either end of the curve, in progress per unit of the flight's time.
        var startSlope: CGFloat
        var endSlope: CGFloat
        var landed: () -> Void
    }

    func begin(_ pages: Pages, forward: Bool, grip: CGFloat = 0.82) {
        flight = nil
        self.pages = pages
        self.forward = forward
        self.grip = min(max(grip, 0.55), 0.95)
        progress = 0
        target = 0
        velocity = 0
        isActive = true
        startTicking()
        redraw()
    }

    func drag(to progress: CGFloat) {
        guard isActive, flight == nil else { return }
        target = min(max(progress, 0), 1)
    }

    /// Lets go. Turning, the page carries on at the speed it was moving and gathers pace
    /// as it falls, landing flat — the way a page drops once it's past upright. Settling
    /// back, it eases down where it started.
    func release(completing: Bool, then: @escaping (_ turned: Bool) -> Void) {
        guard isActive else { return }
        let remaining = completing ? 1 - progress : progress
        let duration: CFTimeInterval = completing
            ? min(0.7, max(0.32, 0.2 + 0.55 * Double(remaining)))
            : min(0.45, max(0.22, 0.15 + 0.4 * Double(remaining)))
        // Keep the momentum it had, but never send it backward at the start of a fall.
        let carried = completing ? max(0, velocity) : min(0, velocity)
        fly(
            to: completing ? 1 : 0,
            duration: duration,
            startSlope: carried * CGFloat(duration),
            endSlope: completing ? 1.6 * remaining : 0
        ) { [weak self] in
            then(completing)
            if !completing { self?.end() }
        }
    }

    /// A whole turn, start to finish, for a click: lifts gently, falls over.
    func play(_ pages: Pages, forward: Bool, then: @escaping () -> Void) {
        begin(pages, forward: forward)
        fly(to: 1, duration: 0.75, startSlope: 0.2, endSlope: 1.5) { then() }
    }

    /// Takes the curl down. Called once the book underneath shows the turned-to spread.
    func end() {
        link?.invalidate()
        link = nil
        flight = nil
        isActive = false
        pages = nil
        progress = 0
        target = 0
        velocity = 0
    }

    // MARK: - Motion

    private func fly(to destination: CGFloat, duration: CFTimeInterval, startSlope: CGFloat, endSlope: CGFloat, landed: @escaping () -> Void) {
        // A fast flick hands the curve a steep start; too steep and it overshoots the
        // landing and swings back — the page bounced. Keeping both slopes within three
        // times the distance (Fritsch–Carlson) keeps the curve heading one way only.
        let distance = abs(destination - progress)
        var startSlope = startSlope, endSlope = endSlope
        if distance > 0.0001 {
            let a = abs(startSlope) / distance, b = abs(endSlope) / distance
            let size = (a * a + b * b).squareRoot()
            if size > 3 {
                startSlope *= 3 / size
                endSlope *= 3 / size
            }
        } else {
            startSlope = 0
            endSlope = 0
        }
        flight = Flight(
            from: progress, to: destination, start: CACurrentMediaTime(), duration: duration,
            startSlope: startSlope, endSlope: endSlope, landed: landed
        )
        startTicking()
    }

    private func startTicking() {
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.tick() }, selector: #selector(DisplayLinkTarget.fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = max(1.0 / 240, now - lastTick)
        lastTick = now
        let before = progress

        if let flight {
            let t = CGFloat(min(1, (now - flight.start) / flight.duration))
            let next = Self.hermite(t, from: flight.from, to: flight.to, startSlope: flight.startSlope, endSlope: flight.endSlope)
            // And never a step backward on the way, whatever the curve says.
            progress = flight.to >= flight.from ? max(progress, next) : min(progress, next)
            if t >= 1 {
                progress = flight.to
                self.flight = nil
                redraw()
                flight.landed()
                return
            }
        } else {
            // Follow the thumb with a short lag: smooth, but never feeling behind.
            let follow = 1 - exp(-dt / 0.07)
            progress += (target - progress) * CGFloat(follow)
        }

        velocity = (progress - before) / CGFloat(dt)
        redraw()
    }

    /// A curve from `from` to `to` that leaves at one speed and arrives at another.
    private static func hermite(_ t: CGFloat, from p0: CGFloat, to p1: CGFloat, startSlope m0: CGFloat, endSlope m1: CGFloat) -> CGFloat {
        let t2 = t * t, t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0
            + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
        return min(max(value, 0), 1)
    }
}

/// CADisplayLink holds its target strongly; this keeps `PageCurl` out of that cycle.
private final class DisplayLinkTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

// MARK: - View

/// Draws a `PageCurl` over the book, the same size as the open spread.
struct PageCurlView: UIViewRepresentable {
    let curl: PageCurl
    let paper: Color

    func makeCoordinator() -> CurlRenderer { CurlRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        context.coordinator.curl = curl
        curl.redraw = { [weak view] in view?.setNeedsDisplay() }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.curl = curl
        context.coordinator.paper = paper
        view.setNeedsDisplay()
    }
}

// MARK: - Renderer

/// Renders the turn: the two pages lying under it, then the turning page as a mesh bent
/// around a cylinder in the vertex shader.
@MainActor
final class CurlRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()
    weak var curl: PageCurl?
    var paper: Color = .white

    private var queue: MTLCommandQueue?
    private var sheetPipeline: MTLRenderPipelineState?
    private var flatPipeline: MTLRenderPipelineState?
    private var depth: MTLDepthStencilState?
    private var grid: MTLBuffer?
    private var indices: MTLBuffer?
    private var indexCount = 0
    private var textures: [ObjectIdentifier: MTLTexture] = [:]
    private var loadedPages: (left: CGImage, right: CGImage, front: CGImage, back: CGImage)?
    private var loaded: [MTLTexture] = []

    /// Mesh resolution: enough rows that the roll reads as a smooth curve on a 4K screen.
    private static let columns = 64
    private static let rows = 48

    override init() {
        super.init()
        guard let device else { return }
        queue = device.makeCommandQueue()

        do {
            let library = try device.makeLibrary(source: Self.shaders, options: nil)
            let sheet = MTLRenderPipelineDescriptor()
            sheet.vertexFunction = library.makeFunction(name: "sheetVertex")
            sheet.fragmentFunction = library.makeFunction(name: "sheetFragment")
            sheet.colorAttachments[0].pixelFormat = .bgra8Unorm
            sheet.depthAttachmentPixelFormat = .depth32Float
            sheetPipeline = try device.makeRenderPipelineState(descriptor: sheet)

            let flat = MTLRenderPipelineDescriptor()
            flat.vertexFunction = library.makeFunction(name: "flatVertex")
            flat.fragmentFunction = library.makeFunction(name: "flatFragment")
            flat.colorAttachments[0].pixelFormat = .bgra8Unorm
            flat.depthAttachmentPixelFormat = .depth32Float
            flatPipeline = try device.makeRenderPipelineState(descriptor: flat)
        } catch {
            print("LingoBook: page curl shaders failed to build: \(error)")
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depth = device.makeDepthStencilState(descriptor: depthDescriptor)

        var vertices: [SIMD2<Float>] = []
        for row in 0...Self.rows {
            for column in 0...Self.columns {
                vertices.append(SIMD2(Float(column) / Float(Self.columns), Float(row) / Float(Self.rows)))
            }
        }
        var triangles: [UInt32] = []
        let stride = UInt32(Self.columns + 1)
        for row in 0..<UInt32(Self.rows) {
            for column in 0..<UInt32(Self.columns) {
                let a = row * stride + column, b = a + 1, c = a + stride, d = c + 1
                triangles += [a, c, b, b, c, d]
            }
        }
        grid = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride)
        indices = device.makeBuffer(bytes: triangles, length: triangles.count * MemoryLayout<UInt32>.stride)
        indexCount = triangles.count
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private struct Uniforms {
        var sheet: SIMD2<Float>
        var progress: Float
        var grip: Float
        var radius: Float
        var mirror: Float
        var paper: SIMD4<Float>
    }

    func draw(in view: MTKView) {
        guard let curl, curl.isActive, let pages = curl.pages,
              let queue, let sheetPipeline, let flatPipeline,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer() else { return }

        if loadedPages.map({ $0.left !== pages.left || $0.right !== pages.right || $0.front !== pages.front || $0.back !== pages.back }) ?? true {
            loaded = [pages.left, pages.right, pages.front, pages.back].compactMap(texture)
            loadedPages = (pages.left, pages.right, pages.front, pages.back)
        }
        guard loaded.count == 4 else { return }

        let paperColor = SIMD4<Float>(UIColor(paper).rgba)
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(paperColor.x), green: Double(paperColor.y), blue: Double(paperColor.z), alpha: 1
        )
        pass.colorAttachments[0].loadAction = .clear
        pass.depthAttachment.clearDepth = 1

        // The page is half the view; distances are in points so the roll keeps its shape
        // at any size.
        let size = view.bounds.size
        let width = Float(size.width / 2), height = Float(size.height)
        let progress = Float(curl.progress)
        // The roll tightens as the page comes down and is gone as it lands, so the last
        // frame is the turned-to page exactly — nothing jumps when the real one takes over.
        let radius = max(0.5, width * 0.12 * (1 - progress))
        var uniforms = Uniforms(
            sheet: SIMD2(width, height),
            progress: progress,
            grip: Float(curl.grip) * height,
            radius: radius,
            mirror: curl.forward ? 0 : 1,
            paper: paperColor
        )

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setDepthStencilState(depth)

        // The two pages lying flat: on the side being uncovered, the one being turned to.
        encoder.setRenderPipelineState(flatPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        for (side, texture) in [(Float(0), loaded[0]), (Float(1), loaded[1])] {
            var which = side
            encoder.setVertexBytes(&which, length: MemoryLayout<Float>.stride, index: 2)
            encoder.setFragmentBytes(&which, length: MemoryLayout<Float>.stride, index: 2)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // The page in the air.
        if let grid, let indices {
            encoder.setRenderPipelineState(sheetPipeline)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(grid, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(loaded[2], index: 0)
            encoder.setFragmentTexture(loaded[3], index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func texture(_ image: CGImage) -> MTLTexture? {
        guard let device else { return nil }
        let loader = MTKTextureLoader(device: device)
        do {
            return try loader.newTexture(cgImage: image, options: [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .generateMipmaps: false
            ])
        } catch {
            print("LingoBook: page curl couldn't load a page image: \(error)")
            return nil
        }
    }

    /// Geometry: each page is W×H points, the spine at x = W in a 2W-wide view. A
    /// forward turn lifts the right page; a backward turn is the same thing mirrored.
    ///
    /// The fold runs perpendicular to the line from the page's held corner (on its outer
    /// edge, at the grip height) to where that corner has been carried. Past the fold
    /// the page wraps a cylinder of `radius`; past half the cylinder it lies face down.
    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 sheet;
        float progress;
        float grip;
        float radius;
        float mirror;
        float4 paper;
    };

    struct SheetOut {
        float4 position [[position]];
        float2 uv;
        float tilt;
    };

    struct Fold { float2 point; float2 dir; bool valid; };

    static Fold fold(constant Uniforms &u) {
        float W = u.sheet.x;
        float2 held = float2(W, u.grip);
        // Carried across the spine, lifting a little on the way like a real page.
        float lift = u.sheet.y * 0.06 * sin(M_PI_F * u.progress);
        float2 now = float2(W - 2.0 * W * u.progress, u.grip - lift);
        float2 d = held - now;
        float len = length(d);
        Fold f;
        f.valid = len > 0.5;
        f.dir = f.valid ? d / len : float2(1, 0);
        f.point = (held + now) * 0.5;
        return f;
    }

    vertex SheetOut sheetVertex(uint vid [[vertex_id]],
                                const device float2 *grid [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
        float2 uv = grid[vid];
        float W = u.sheet.x, H = u.sheet.y, R = u.radius;
        float2 p = float2(uv.x * W, uv.y * H);
        float3 q = float3(p, 0);
        float angle = 0;

        Fold f = fold(u);
        if (f.valid) {
            float s = dot(p - f.point, f.dir);
            if (s > 0) {
                float2 base = p - f.dir * s;
                if (s < M_PI_F * R) {
                    angle = s / R;
                    q.xy = base + f.dir * R * sin(angle);
                    q.z = R * (1 - cos(angle));
                } else {
                    angle = M_PI_F;
                    q.xy = base - f.dir * (s - M_PI_F * R);
                    q.z = 2 * R;
                }
            }
        }

        float x = u.mirror > 0.5 ? W - q.x : W + q.x;
        SheetOut o;
        o.position = float4(x / W - 1.0, 1.0 - 2.0 * q.y / H, 0.5 - 0.4 * q.z / (2.0 * R + 1.0), 1);
        o.uv = uv;
        o.tilt = cos(angle);
        return o;
    }

    fragment float4 sheetFragment(SheetOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(1)]],
                                  texture2d<float> front [[texture(0)]],
                                  texture2d<float> back [[texture(1)]]) {
        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        bool mirror = u.mirror > 0.5;
        // Which side faces us follows from how far round the roll this point has gone.
        if (in.tilt >= 0) {
            float2 uv = float2(mirror ? 1 - in.uv.x : in.uv.x, in.uv.y);
            float4 c = front.sample(smp, uv);
            // Darker as the page turns away from the light, toward the roll — but only
            // while the roll is wide enough to read as a curve. Squeezed into a few pixels
            // as the page lands, the same shading is a hard dark line down the spine.
            float roll = 1.0 - smoothstep(0.65, 0.95, u.progress);
            float light = mix(1.0, 0.74 + 0.26 * in.tilt, roll);
            float sheen = pow(1 - in.tilt, 6) * 0.10 * roll;
            return float4(c.rgb * light + sheen, 1);
        } else {
            float2 uv = float2(mirror ? in.uv.x : 1 - in.uv.x, in.uv.y);
            float4 c = back.sample(smp, uv);
            // The back of a page: a touch washed, like paper seen against the light, and
            // a little dimmer than the front — it faces away from the light, darkest
            // where it comes off the roll.
            float3 paper = mix(c.rgb, u.paper.rgb, 0.08);
            float light = 0.84 + 0.10 * (-in.tilt);
            float sheen = pow(1 + in.tilt, 6) * 0.05;
            // As it comes down flat it's lit like the page it's becoming, so the last
            // frame and the real page are the same picture — no brightening at the end.
            float landing = smoothstep(0.65, 0.95, u.progress);
            return float4(mix(paper * light + sheen, c.rgb, landing), 1);
        }
    }

    struct FlatOut {
        float4 position [[position]];
        float2 uv;
        float2 sheetPoint;
    };

    vertex FlatOut flatVertex(uint vid [[vertex_id]],
                              constant Uniforms &u [[buffer(1)]],
                              constant float &side [[buffer(2)]]) {
        float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 uv = corners[vid];
        float W = u.sheet.x, H = u.sheet.y;
        float x = side * W + uv.x * W;
        FlatOut o;
        o.position = float4(x / W - 1.0, 1.0 - 2.0 * uv.y, 0.9, 1);
        o.uv = uv;
        // Where this point sits in the turning page's own coordinates.
        float local = u.mirror > 0.5 ? W - x : x - W;
        o.sheetPoint = float2(local, uv.y * H);
        return o;
    }

    fragment float4 flatFragment(FlatOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(1)]],
                                 constant float &side [[buffer(2)]],
                                 texture2d<float> page [[texture(0)]]) {
        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        float4 c = page.sample(smp, in.uv);
        float shade = 1;
        // Shadow under the lifted page, deepest just inside the roll.
        Fold f = fold(u);
        bool uncovered = (u.mirror > 0.5) ? side < 0.5 : side > 0.5;
        if (f.valid && uncovered) {
            float s = dot(in.sheetPoint - f.point, f.dir);
            if (s > 0) {
                float reach = u.sheet.x * 0.10;
                // Light gets in at the page's top and bottom edges, so the shadow thins
                // there instead of stopping in a line.
                float edges = smoothstep(0.0, 0.06, in.uv.y) * smoothstep(1.0, 0.94, in.uv.y);
                shade = 1 - 0.22 * exp(-s / reach) * (1 - smoothstep(0.6, 1.0, u.progress)) * edges;
            }
        }
        // The turned-over part of the page lies on the book and casts a soft shadow
        // just past its free edge, onto whichever page it's lying across.
        if (f.valid) {
            float W = u.sheet.x, R = u.radius;
            float2 outerEdge = float2(W, in.sheetPoint.y);
            float edge = dot(outerEdge - f.point, f.dir) - M_PI_F * R;
            float beyond = -dot(in.sheetPoint - f.point, f.dir) - edge;
            if (edge > 0 && beyond > 0) {
                float edges = smoothstep(0.0, 0.06, in.uv.y) * smoothstep(1.0, 0.94, in.uv.y);
                shade *= 1 - 0.20 * exp(-beyond / (W * 0.035)) * edges * (1 - smoothstep(0.75, 1.0, u.progress));
            }
        }
        return float4(c.rgb * shade, 1);
    }
    """
}

private extension UIColor {
    var rgba: SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }
}

// MARK: - Snapshots

/// Pictures of pages for a turn, drawn the way the screen draws them.
///
/// Pages are SwiftUI wrapping UIKit text views, which SwiftUI's own image renderer can't
/// draw — so each is hosted for a moment, out of sight behind the app, and photographed.
@MainActor
enum PageSnapshotter {
    static func image(of content: some View, size: CGSize, background: Color) -> CGImage? {
        guard size.width > 0, size.height > 0,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return nil }

        let host = UIHostingController(rootView: content.frame(width: size.width, height: size.height).background(background))
        host.safeAreaRegions = []
        host.view.backgroundColor = UIColor(background)
        // Inside the window, behind the app's own (opaque) view: a text view draws only
        // the part of itself it thinks is on screen, so one parked off the edge of the
        // window photographs as a blank page with a sliver of text.
        host.view.frame = CGRect(origin: .zero, size: size)
        window.insertSubview(host.view, at: 0)
        defer { host.view.removeFromSuperview() }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        // Plain 8-bit sRGB: the GPU's texture loader won't take the extended-range
        // format a renderer picks by default on a wide-colour display.
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        return image.cgImage
    }
}
