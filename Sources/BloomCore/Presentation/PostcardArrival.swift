import Foundation

/// A postcard landing on the ground it is drawn on, and the numbers that make it read as an
/// object rather than as a picture fading in.
///
/// One idea, done once. The postcard is the only physical thing in this app, so the screen it is
/// on gets exactly one movement: the card comes in from above and to the side, tilted, and settles
/// where it lands. There is no stamp pressing itself, no card being held and tipped, and no second
/// pass. Three ideas played together is a title sequence; one is a card arriving.
///
/// **The shadow is the whole of it, and it is the part that is easy to leave out.** A card that
/// travels with a fixed shadow reads as a sticker sliding across glass, because a shadow is the
/// only thing on a flat screen that says how far an object is from the surface under it. So the
/// shadow starts wide, soft and far off, and contracts and darkens as the card comes down, which
/// is what a real card's shadow does over a desk. `SettleTests` holds that: a start shadow that
/// stopped being the looser of the two would take the landing with it.
///
/// **It plays once and then rests.** Nothing here repeats, and the whole thing is under a second,
/// because this window is one somebody leaves open on a second display. A card that kept landing
/// would be a timer running in the background of a machine that has several agents building on it.
///
/// The numbers are here rather than in the view for the reason `TranscriptMotion`'s are: a curve
/// written inside a `body` is a curve nothing can test, and the two invariants that actually
/// matter (that Reduce Motion gets no movement at all, and that the shadow tightens rather than
/// spreads) are both invariants about numbers.
public enum PostcardArrival {
    /// How far off square the card lies when it has landed, in degrees.
    ///
    /// Not zero, and not part of the movement: a card put down on a desk is never square to it,
    /// and a postcard drawn dead level reads as a rectangle with writing in it. Anticlockwise,
    /// because the card arrives from the upper right and a settle carries the last of its
    /// rotation past the vertical rather than stopping on it.
    ///
    /// Reduce Motion keeps this. The setting is about movement, and a card lying at an angle is
    /// not moving; taking the angle away as well would leave that reader looking at a different
    /// drawing rather than at the same drawing held still. The same rule `BrandWater` follows
    /// when it keeps its pools and drops their drift.
    public static let restAngle: Double = -2.5

    /// A shadow, as the three numbers a shadow is made of.
    ///
    /// `blur` and `drop` are points and `opacity` is what it carries. Named rather than passed as
    /// a tuple because the two ends of the fall are compared with each other in a test, and a
    /// tuple of three doubles is three chances to compare the wrong pair.
    public struct CardShadow: Equatable, Sendable {
        public let blur: Double
        public let drop: Double
        public let opacity: Double

        public init(blur: Double, drop: Double, opacity: Double) {
            self.blur = blur
            self.drop = drop
            self.opacity = opacity
        }
    }

    /// The card's whole arrival: where it starts, how long it takes, and what its shadow does on
    /// the way down.
    public struct Settle: Equatable, Sendable {
        /// How long the fall takes.
        public let seconds: Double
        /// How long after the screen appears it begins.
        ///
        /// A beat rather than nothing. The window and its plinth arrive on the same frame, and a
        /// card already falling on the first frame reads as part of the window being drawn rather
        /// than as something turning up on it.
        public let delay: Double
        /// Where the card starts, in points, measured from where it lands. Positive x is to the
        /// trailing edge and negative y is above, which is the corner a card posted through a
        /// door comes from.
        public let offsetX: Double
        public let offsetY: Double
        /// How far off square it starts, in degrees, before it settles to `restAngle`.
        public let startAngle: Double
        /// How much larger it is at the top of the fall, as a multiple of its landed size. Above
        /// one, which is what says it is nearer the eye than the surface it is heading for.
        public let startScale: Double
        /// What the card carries on the first frame.
        ///
        /// Nothing, and it is the one part of this that is not physics. A card has to come from
        /// somewhere, and the two honest ways to do that are to fly in from outside the screen or
        /// to be placed. Flying in needs the drawing clipped to a stage, which is a constraint on
        /// every surface that ever shows this card; being placed needs the card to exist a moment
        /// before it lands, which is a quarter of a second of fade under a movement nobody is
        /// looking at the start of. The second is cheaper and it is what a hand setting a card
        /// down looks like anyway.
        public let startOpacity: Double
        /// The shadow at the top of the fall, and the shadow it lands on.
        public let startShadow: CardShadow
        public let restShadow: CardShadow

        public init(
            seconds: Double,
            delay: Double,
            offsetX: Double,
            offsetY: Double,
            startAngle: Double,
            startScale: Double,
            startOpacity: Double,
            startShadow: CardShadow,
            restShadow: CardShadow
        ) {
            self.seconds = seconds
            self.delay = delay
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.startAngle = startAngle
            self.startScale = startScale
            self.startOpacity = startOpacity
            self.startShadow = startShadow
            self.restShadow = restShadow
        }

        /// When the card has stopped, measured from the moment the screen appeared.
        public var endsAfter: Double { delay + seconds }
    }

    /// The shadow a landed card carries, which is also the one a reader with Reduce Motion on sees
    /// from the first frame.
    ///
    /// Tight and close, because the card is lying on the ground rather than floating over it.
    /// It is the same seat the About window gives the app's mark, at a card's scale.
    public static let restShadow = CardShadow(blur: 10, drop: 5, opacity: 0.32)

    /// The arrival, or nothing at all.
    ///
    /// **Nil rather than a slower version of it.** Reduce Motion means the card is already lying
    /// there when the screen opens, exactly as it will look a second later, and every call site in
    /// this app answers that setting the same way: `TranscriptMotion.arrival` returns nothing,
    /// `Motion`'s call sites pass nil, `BrandWater` stops rather than slows. An absence rather
    /// than a zeroed `Settle`, so that a caller cannot honour half of one and leave a card sitting
    /// a hundred points above where it belongs with nothing left to move it.
    public static func settle(reduceMotion: Bool) -> Settle? {
        guard !reduceMotion else { return nil }
        return Settle(
            // Just over half a second, which is longer than anything else in this app moves for.
            // Everything else here is furniture answering a press, and the argument on `Motion` is
            // that furniture which springs is a toy. This is not furniture: it is an object with a
            // weight, arriving without being asked, and a card that came to rest in the fifth of a
            // second a pane travels in would have been dropped rather than put down.
            seconds: 0.55,
            // A beat, so the card lands onto a window that is already there rather than arriving
            // with it. Short enough that somebody who presses straight through the welcome
            // sequence still sees it.
            delay: 0.10,
            // A short way up and across, because the card is being set down rather than posted
            // through a door. Thirty points is about an eighth of the card's own height, which is
            // the distance a hand holds something over the place it is about to put it.
            offsetX: 16,
            offsetY: -30,
            // Eight degrees off where it lands, so the card turns a little as it comes down.
            // Past about fifteen the eye reads a spin, and a spinning postcard is a graphic.
            startAngle: 8,
            // A tenth larger, which on a 340 point card is 34 points of width: the same order as
            // the drop, so the two read as one movement towards the surface rather than as a
            // slide with a zoom on it.
            startScale: 1.10,
            startOpacity: 0,
            // Wide, soft and well below the card, which is the shadow of something held a hand's
            // width off the surface. It contracts to `restShadow` on the way down, and that
            // contraction is the whole reason this reads as depth rather than as a slide.
            startShadow: CardShadow(blur: 30, drop: 22, opacity: 0.20),
            restShadow: restShadow
        )
    }

    /// How long a screen has to wait before nothing on it is moving any more.
    ///
    /// Zero when Reduce Motion is on, which is the honest answer rather than a courtesy: there is
    /// nothing to wait for.
    /// A stamp being pressed on, for the About panel, which draws no card.
    ///
    /// **A different gesture from the card's, and it has to be.** A card is set down: it travels,
    /// it tilts, and its shadow contracts as it approaches the paper. A stamp is pressed: it does
    /// not travel at all, it arrives slightly too large and settles onto the surface, which is what
    /// a thumb does to a stamp. Reusing `settle` here would have put a card's descent on an object
    /// that is already lying on the card.
    ///
    /// Nil under Reduce Motion for the same reason `settle` is nil: a caller handed a shortened
    /// animation can honour half of it, and a caller handed nothing cannot.
    public static func press(reduceMotion: Bool) -> Press? {
        guard !reduceMotion else { return nil }
        return Press()
    }

    /// The stamp's arrival. No offset and no angle: what changes is scale and ink.
    public struct Press: Equatable, Sendable {
        /// Larger than its rest size, so it comes down onto the panel rather than growing into it.
        /// A tenth, which is the same overshoot the card starts at, so the two readings of "an
        /// object arriving" agree across the app.
        public var startScale: Double = 1.10
        public var startOpacity: Double = 0
        /// Shorter than the card's. A press is one movement and a card's descent is a journey, and
        /// a stamp that took the card's time would read as slow rather than as deliberate.
        public var seconds: Double = 0.32
        /// After the panel's own text has arrived, so the stamp is a thing that lands on a page
        /// rather than part of the page appearing.
        public var delay: Double = 0.18

        public init() {}

        public var endsAfter: Double { delay + seconds }
    }

    public static func seconds(reduceMotion: Bool) -> Double {
        settle(reduceMotion: reduceMotion)?.endsAfter ?? 0
    }
}
