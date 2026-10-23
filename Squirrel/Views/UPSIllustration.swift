import SquirrelCore
import SwiftUI

/// Which drawing the dashboard header shows for a UPS, matched on the
/// reported maker and model. Anything unrecognised gets a plain tower, or a
/// plain rack unit when its model code says it is rack-mounted.
enum UPSIllustrationKind: String, Equatable, CaseIterable {
    case unifiRack, unifiTower
    case apcBackUPS, apcSmartUPS, cyberPowerTower, eatonTower
    /// The black 2U-with-a-screen that APC, CyberPower, Eaton and Tripp Lite
    /// rack units all share closely enough to draw once.
    case lcdRack
    case genericTower, genericRack

    init(reading: UPSReading?) {
        self = Self.classify(maker: reading.flatMap { UPSNaming.manufacturer(in: $0) }, model: reading?.model)
    }

    /// What the picture picker calls each drawing.
    var title: String {
        switch self {
        case .unifiRack: return "UniFi UPS 2U"
        case .unifiTower: return "UniFi UPS Tower"
        case .apcBackUPS: return "APC Back-UPS"
        case .apcSmartUPS: return "APC Smart-UPS"
        case .cyberPowerTower: return "CyberPower Tower"
        case .eatonTower: return "Eaton Tower"
        case .lcdRack: return "Rack with Display"
        case .genericTower: return "Tower"
        case .genericRack: return "Rack"
        }
    }

    /// `maker` is the normalised name from `UPSNaming.manufacturer(in:)`.
    static func classify(maker: String?, model: String?) -> Self {
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        if maker == "Ubiquiti" {
            return model.contains("TOWER") ? .unifiTower : .unifiRack
        }
        if isRackModel(model) {
            return ["APC", "CyberPower", "Eaton", "Tripp Lite"].contains(maker ?? "") ? .lcdRack : .genericRack
        }
        switch maker {
        case "APC": return smartUPSPrefixes.contains(where: model.hasPrefix) ? .apcSmartUPS : .apcBackUPS
        case "CyberPower": return .cyberPowerTower
        case "Eaton": return .eatonTower
        default: return .genericTower
        }
    }

    /// Smart-UPS report "Smart-UPS 1500" or their SKU; everything else APC
    /// sells to homes and small offices is a Back-UPS.
    private static let smartUPSPrefixes = ["SMART-UPS", "SMT", "SMC", "SMX", "SMV", "SRT", "SRV", "SUA", "SURT", "SCL"]

    /// Rack units say so in their model code: "SMT1500RMI2U", "OR1500LCDRM1U",
    /// "PR1500ELCDRT2U", "5PX1500IRT" and "5SC1500IR" are all rack-mounted,
    /// while "CP1500PFCLCD" and "5SC1500I" are towers.
    static func isRackModel(_ model: String) -> Bool {
        let model = model.uppercased()
        return model.contains("RM") || model.contains("RACK")
            || model.range(of: #"[1-4]U([^A-Z0-9]|$)"#, options: .regularExpression) != nil
            || model.range(of: #"\dI?RT"#, options: .regularExpression) != nil
            || model.range(of: #"\dIR([^A-Z]|$)"#, options: .regularExpression) != nil
    }
}

extension UPSDevice {
    /// The picture the user chose for this UPS, or the one its reading suggests.
    func illustration(for reading: UPSReading?) -> UPSIllustrationKind {
        illustrationOverride.flatMap(UPSIllustrationKind.init(rawValue:)) ?? UPSIllustrationKind(reading: reading)
    }
}

/// A small vector drawing of the UPS. These are original drawings of each
/// product's front, never vendor images, and deliberately carry no logos.
/// Drawn at 115 × 88 and scaled to fit whatever frame it is given.
struct UPSDeviceIllustration: View {
    let kind: UPSIllustrationKind
    var cornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.primary.opacity(0.035))
            Canvas { context, size in
                let scale = min(size.width / UPSDrawing.size.width, size.height / UPSDrawing.size.height)
                var context = context
                context.translateBy(x: (size.width - UPSDrawing.size.width * scale) / 2, y: (size.height - UPSDrawing.size.height * scale) / 2)
                context.scaleBy(x: scale, y: scale)
                UPSDrawing.draw(kind, in: context)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A grid of every drawing, for when Squirrel recognised a UPS wrongly.
/// "Automatic" shows what Squirrel would pick on its own.
struct UPSIllustrationPicker: View {
    let detected: UPSIllustrationKind
    let selection: UPSIllustrationKind?
    let choose: (UPSIllustrationKind?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Picture").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(92), spacing: 10), count: 4), spacing: 10) {
                tile(kind: detected, title: "Automatic", isSelected: selection == nil) { choose(nil) }
                ForEach(UPSIllustrationKind.allCases, id: \.self) { kind in
                    tile(kind: kind, title: kind.title, isSelected: selection == kind) { choose(kind) }
                }
            }
            Text("Automatic picks a picture from the maker and model the UPS reports.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func tile(kind: UPSIllustrationKind, title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                UPSDeviceIllustration(kind: kind, cornerRadius: 10)
                    .frame(width: 92, height: 70)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Every drawing is laid out in the header's 115 × 88 point frame.
private enum UPSDrawing {
    static let size = CGSize(width: 115, height: 88)
    static let blue = Color(red: 0.36, green: 0.56, blue: 1)
    static let green = Color(red: 0.3, green: 0.8, blue: 0.42)

    static func draw(_ kind: UPSIllustrationKind, in context: GraphicsContext) {
        switch kind {
        case .unifiRack: unifiRack(context)
        case .unifiTower: unifiTower(context)
        case .apcBackUPS: apcBackUPS(context)
        case .apcSmartUPS: apcSmartUPS(context)
        case .cyberPowerTower: cyberPowerTower(context)
        case .eatonTower: eatonTower(context)
        case .lcdRack: lcdRack(context)
        case .genericTower: genericTower(context)
        case .genericRack: genericRack(context)
        }
    }

    // MARK: UniFi

    /// The UniFi UPS 2U front panel: a flat 5:1 grey face with five vent slots
    /// along each edge and a status LED at the left.
    private static func unifiRack(_ context: GraphicsContext) {
        let face = CGRect(x: 7, y: 33, width: 101, height: 20.2)
        let s = face.width / 600
        func scaled(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: face.minX + x * s, y: face.minY + y * s, width: w * s, height: h * s)
        }
        let panel = Path(roundedRect: face, cornerRadius: 2.2)
        context.fill(panel, with: .linearGradient(Gradient(colors: [Color(white: 0.84), Color(white: 0.68)]), startPoint: CGPoint(x: 0, y: face.minY), endPoint: CGPoint(x: 0, y: face.maxY)))
        context.stroke(panel, with: .color(Color(white: 0.42)), lineWidth: 0.6)
        context.fill(Path(scaled(10, 3, 580, 2)), with: .color(.white.opacity(0.6)))
        for i in 0..<5 {
            let x = 26 + Double(i) * 111
            for y in [10.0, 101.0] {
                context.fill(Path(roundedRect: scaled(x, y, 104, 9), cornerRadius: 0.8), with: .color(Color(white: 0.2)))
            }
        }
        context.fill(Path(ellipseIn: scaled(22, 54, 10, 10)), with: .color(Color(red: 0.2, green: 0.52, blue: 1)))
        context.stroke(Path(roundedRect: scaled(40, 54, 14, 10), cornerRadius: 1), with: .color(Color(white: 0.3)), lineWidth: 0.35)
    }

    /// The UniFi UPS Tower: a white column with perforated side rails in three
    /// runs, the blue power ring, five LED dots and the battery door seam, in a
    /// 500-wide reference scaled down.
    private static func unifiTower(_ context: GraphicsContext) {
        let face = CGRect(x: 45, y: 8, width: 25, height: 71)
        let s = face.width / 500
        func scaled(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: face.minX + x * s, y: face.minY + y * s, width: w * s, height: h * s)
        }
        shadow(under: face, context)
        let column = Path(roundedRect: face, cornerRadius: 3.2)
        context.fill(column, with: .color(Color(white: 0.9)))
        context.stroke(column, with: .color(Color(white: 0.66)), lineWidth: 0.5)
        context.fill(Path(roundedRect: scaled(30, 0, 440, 1425), cornerRadius: 2.6), with: .linearGradient(Gradient(colors: [.white, Color(white: 0.95)]), startPoint: CGPoint(x: 0, y: face.minY), endPoint: CGPoint(x: 0, y: face.maxY)))
        for x in [12.0, 474.0] {
            for (y, h) in [(125.0, 345.0), (515.0, 390.0), (955.0, 345.0)] {
                context.fill(Path(roundedRect: scaled(x, y, 14, h), cornerRadius: 0.4), with: .color(Color(white: 0.58)))
            }
        }
        context.fill(Path(scaled(37, 498, 426, 6)), with: .color(Color(white: 0.78)))
        context.stroke(Path(ellipseIn: scaled(208, 201, 84, 84)), with: .color(blue), lineWidth: 0.55)
        for i in 0..<5 {
            context.fill(Path(ellipseIn: scaled(200 + Double(i) * 21, 381, 12, 12)), with: .color(Color(red: 0.3, green: 0.5, blue: 1)))
        }
    }

    // MARK: Popular towers

    /// APC Back-UPS Pro: a tall black tower with softened corners, grey side
    /// trim, a small screen and a ringed power button.
    private static func apcBackUPS(_ context: GraphicsContext) {
        let body = CGRect(x: 45, y: 10, width: 25, height: 69)
        shadow(under: body, context)
        blackCase(body, radius: 3.5, context)
        for x in [45.8, 68.2] {
            context.fill(Path(roundedRect: CGRect(x: x, y: 15, width: 1, height: 59), cornerRadius: 0.5), with: .color(Color(white: 0.34)))
        }
        screen(CGRect(x: 51, y: 18, width: 13, height: 9), context)
        button(CGPoint(x: 57.5, y: 33), radius: 2, context)
        context.fill(Path(ellipseIn: CGRect(x: 56.9, y: 32.4, width: 1.2, height: 1.2)), with: .color(green))
        hairline(from: CGPoint(x: 49, y: 42), to: CGPoint(x: 66, y: 42), context)
    }

    /// APC Smart-UPS tower: wider and squarer, with a raised display bezel
    /// across the top and slotted vents below.
    private static func apcSmartUPS(_ context: GraphicsContext) {
        let body = CGRect(x: 38, y: 16, width: 39, height: 62)
        shadow(under: body, context)
        blackCase(body, radius: 2, context)
        context.fill(Path(roundedRect: CGRect(x: 41, y: 19, width: 33, height: 16), cornerRadius: 1.5), with: .color(Color(white: 0.2)))
        screen(CGRect(x: 44, y: 22, width: 13, height: 9.5), context)
        for x in [62.0, 67.0] {
            for y in [24.5, 29.0] { button(CGPoint(x: x, y: y), radius: 1.1, context) }
        }
        context.fill(Path(ellipseIn: CGRect(x: 70.6, y: 23.9, width: 1.2, height: 1.2)), with: .color(green))
        var vents = Path()
        for y in stride(from: 42.0, through: 73, by: 3) {
            vents.addRoundedRect(in: CGRect(x: 43, y: y, width: 29, height: 1), cornerSize: CGSize(width: 0.5, height: 0.5))
        }
        context.fill(vents, with: .color(Color(white: 0.24)))
    }

    /// CyberPower's PFC and Value towers: tall and narrow, with a lighter
    /// centre panel carrying the screen and a pair of buttons.
    private static func cyberPowerTower(_ context: GraphicsContext) {
        let body = CGRect(x: 44, y: 8, width: 27, height: 71)
        shadow(under: body, context)
        blackCase(body, radius: 2, context)
        let panel = Path(roundedRect: CGRect(x: 48, y: 10, width: 19, height: 67), cornerRadius: 1.5)
        context.fill(panel, with: .color(Color(white: 0.17)))
        context.stroke(panel, with: .color(Color(white: 0.26)), lineWidth: 0.4)
        screen(CGRect(x: 50, y: 19, width: 15, height: 12), context)
        for x in [51.0, 59.0] {
            context.stroke(Path(roundedRect: CGRect(x: x, y: 35, width: 5, height: 2.5), cornerRadius: 1.25), with: .color(Color(white: 0.45)), lineWidth: 0.5)
        }
        hairline(from: CGPoint(x: 50, y: 44), to: CGPoint(x: 65, y: 44), context)
    }

    /// Eaton 5S and 5SC towers: a squat black box with the screen and buttons
    /// along the top and a perforated front.
    private static func eatonTower(_ context: GraphicsContext) {
        let body = CGRect(x: 34, y: 20, width: 47, height: 58)
        shadow(under: body, context)
        blackCase(body, radius: 2.5, context)
        screen(CGRect(x: 40, y: 26, width: 13, height: 9.5), context)
        for x in [58.0, 62.5, 67.0] { button(CGPoint(x: x, y: 30.75), radius: 1.2, context) }
        dotGrid(CGRect(x: 39, y: 42, width: 37, height: 31), spacing: 2.4, size: 0.9, color: Color(white: 0.3), context)
    }

    // MARK: Racks

    /// A black 2U rack unit with a perforated left half and the screen and
    /// buttons on the right, as APC, CyberPower, Eaton and Tripp Lite all do.
    private static func lcdRack(_ context: GraphicsContext) {
        let face = CGRect(x: 7, y: 34, width: 101, height: 20)
        blackCase(face, radius: 1.5, context)
        rackEars(face, color: Color(white: 0.22), holes: Color(white: 0.4), context)
        dotGrid(CGRect(x: 16, y: 38, width: 40, height: 12), spacing: 2.2, size: 0.8, color: Color(white: 0.3), context)
        screen(CGRect(x: 64, y: 38.5, width: 16, height: 9), context)
        for x in [84.0, 88.0, 92.0] { button(CGPoint(x: x, y: 43), radius: 1.1, context) }
        context.fill(Path(ellipseIn: CGRect(x: 97.4, y: 42.4, width: 1.2, height: 1.2)), with: .color(green))
    }

    // MARK: Generic

    /// A plain grey tower: a status light, a power button and vent slots.
    private static func genericTower(_ context: GraphicsContext) {
        let body = CGRect(x: 42, y: 12, width: 31, height: 66)
        shadow(under: body, context)
        let shape = Path(roundedRect: body, cornerRadius: 3)
        context.fill(shape, with: .linearGradient(Gradient(colors: [Color(white: 0.86), Color(white: 0.72)]), startPoint: CGPoint(x: 0, y: body.minY), endPoint: CGPoint(x: 0, y: body.maxY)))
        context.stroke(shape, with: .color(Color(white: 0.5)), lineWidth: 0.5)
        context.fill(Path(ellipseIn: CGRect(x: 56.4, y: 18.9, width: 2.2, height: 2.2)), with: .color(green))
        context.stroke(Path(ellipseIn: CGRect(x: 55.1, y: 24.6, width: 4.8, height: 4.8)), with: .color(Color(white: 0.45)), lineWidth: 0.6)
        var vents = Path()
        for y in stride(from: 48.0, through: 72, by: 3) {
            vents.addRoundedRect(in: CGRect(x: 47, y: y, width: 21, height: 0.9), cornerSize: CGSize(width: 0.45, height: 0.45))
        }
        context.fill(vents, with: .color(Color(white: 0.55)))
    }

    /// A plain grey 2U rack unit: rack ears, a status light, a power button
    /// and vent slots.
    private static func genericRack(_ context: GraphicsContext) {
        let face = CGRect(x: 7, y: 34, width: 101, height: 20)
        let shape = Path(roundedRect: face, cornerRadius: 1.5)
        context.fill(shape, with: .linearGradient(Gradient(colors: [Color(white: 0.82), Color(white: 0.66)]), startPoint: CGPoint(x: 0, y: face.minY), endPoint: CGPoint(x: 0, y: face.maxY)))
        context.stroke(shape, with: .color(Color(white: 0.42)), lineWidth: 0.6)
        rackEars(face, color: Color(white: 0.6), holes: Color(white: 0.35), context)
        context.fill(Path(ellipseIn: CGRect(x: 16, y: 39, width: 2, height: 2)), with: .color(green))
        context.stroke(Path(ellipseIn: CGRect(x: 15, y: 44.5, width: 4, height: 4)), with: .color(Color(white: 0.4)), lineWidth: 0.6)
        var vents = Path()
        for x in stride(from: 60.0, through: 98, by: 3) {
            vents.addRoundedRect(in: CGRect(x: x, y: 38, width: 1.2, height: 12), cornerSize: CGSize(width: 0.6, height: 0.6))
        }
        context.fill(vents, with: .color(Color(white: 0.4)))
    }

    // MARK: Parts

    private static func shadow(under rect: CGRect, _ context: GraphicsContext) {
        context.fill(Path(ellipseIn: CGRect(x: rect.minX - 5, y: rect.maxY - 2, width: rect.width + 10, height: 4)), with: .color(.black.opacity(0.1)))
    }

    /// Black plastic seen straight on, like the UniFi drawings, edged in grey
    /// so it still reads against a dark window.
    private static func blackCase(_ rect: CGRect, radius: Double, _ context: GraphicsContext) {
        let shape = Path(roundedRect: rect, cornerRadius: radius)
        context.fill(shape, with: .linearGradient(Gradient(colors: [Color(white: 0.17), Color(white: 0.09)]), startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
        context.stroke(shape, with: .color(Color(white: 0.4)), lineWidth: 0.5)
    }

    /// A backlit status screen with two lines of readout.
    private static func screen(_ rect: CGRect, _ context: GraphicsContext) {
        context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(Color(red: 0.08, green: 0.2, blue: 0.38)))
        let readout = Color(red: 0.45, green: 0.75, blue: 1)
        context.fill(Path(CGRect(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.28, width: rect.width * 0.6, height: rect.height * 0.24)), with: .color(readout))
        context.fill(Path(CGRect(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.64, width: rect.width * 0.4, height: rect.height * 0.1)), with: .color(readout.opacity(0.7)))
    }

    private static func button(_ center: CGPoint, radius: Double, _ context: GraphicsContext) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: .color(Color(white: 0.5)), lineWidth: 0.5)
    }

    private static func hairline(from start: CGPoint, to end: CGPoint, _ context: GraphicsContext) {
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(Color(white: 0.26)), lineWidth: 0.5)
    }

    private static func dotGrid(_ rect: CGRect, spacing: Double, size: Double, color: Color, _ context: GraphicsContext) {
        var dots = Path()
        for x in stride(from: rect.minX, through: rect.maxX - size, by: spacing) {
            for y in stride(from: rect.minY, through: rect.maxY - size, by: spacing) {
                dots.addEllipse(in: CGRect(x: x, y: y, width: size, height: size))
            }
        }
        context.fill(dots, with: .color(color))
    }

    private static func rackEars(_ face: CGRect, color: Color, holes: Color, _ context: GraphicsContext) {
        for x in [face.minX, face.maxX - 5] {
            context.fill(Path(roundedRect: CGRect(x: x, y: face.minY, width: 5, height: face.height), cornerRadius: 1.5), with: .color(color))
            for y in [face.minY + 3, face.maxY - 5] {
                context.fill(Path(roundedRect: CGRect(x: x + 1.5, y: y, width: 2, height: 2), cornerRadius: 0.5), with: .color(holes))
            }
        }
    }
}
