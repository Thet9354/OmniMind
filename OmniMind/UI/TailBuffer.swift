//
//  TailBuffer.swift
//  OmniMind
//
//  The §5.1 memory invariant made structural: the live-transcript view
//  holds only the newest `capacity` elements, no matter how long the
//  session runs. Persistence owns the full record; this is a tail view
//  of it, so a 3-hour meeting costs the UI the same memory as a 3-minute
//  one — by construction, not by hope.
//

nonisolated struct TailBuffer<Element> {
    private(set) var elements: [Element] = []
    /// Everything ever appended this session, including evicted elements.
    private(set) var totalAppended = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        elements.reserveCapacity(self.capacity)
    }

    mutating func append(_ element: Element) {
        totalAppended += 1
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }

    /// Elements evicted from the live window (still safe in the store).
    var evictedCount: Int { totalAppended - elements.count }

    mutating func removeAll() {
        elements.removeAll(keepingCapacity: true)
        totalAppended = 0
    }
}
