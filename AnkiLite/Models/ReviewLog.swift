import Foundation
import GRDB

/// The button the user pressed when reviewing a card.
enum ReviewEase: Int, Codable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}

/// A record of a single review event.
struct ReviewLog: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reviewLog"

    /// Timestamp in milliseconds (also serves as the primary key).
    var id: Int64
    /// Card id → Card.id.
    var cid: Int64
    /// Pressed button (1=Again, 2=Hard, 3=Good, 4=Easy).
    var ease: Int
    /// New interval after this review.
    var ivl: Int
    /// Interval before this review.
    var lastIvl: Int
    /// New ease factor (× 1000).
    var factor: Int
    /// Time spent on the review (milliseconds).
    var time: Int
    /// Review type (0=learn, 1=review, 2=relearn, 3=cram).
    var type: Int

    enum Columns {
        static let id = Column("id")
        static let cid = Column("cid")
        static let ease = Column("ease")
        static let ivl = Column("ivl")
        static let lastIvl = Column("lastIvl")
        static let factor = Column("factor")
        static let time = Column("time")
        static let type = Column("type")
    }

    init(id: Int64, cid: Int64, ease: Int, ivl: Int, lastIvl: Int, factor: Int, time: Int, type: Int) {
        self.id = id
        self.cid = cid
        self.ease = ease
        self.ivl = ivl
        self.lastIvl = lastIvl
        self.factor = factor
        self.time = time
        self.type = type
    }
}
