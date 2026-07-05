//
//  VectorMath.swift
//  OmniMind
//
//  The retrieval hot path: Accelerate-backed similarity plus a bounded
//  top-K heap, so a full corpus scan is O(n·d) SIMD work + O(n log k)
//  heap maintenance — no full sort, no unbounded allocation.
//

import Accelerate

nonisolated enum VectorMath {
    /// Dot product. Equals cosine similarity when both operands are
    /// L2-normalized — which every stored vector is, by construction.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "dimension mismatch")
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    /// In-place L2 normalization. Zero vectors are left untouched rather
    /// than dividing by zero.
    static func normalize(_ vector: inout [Float]) {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let norm = sumOfSquares.squareRoot()
        guard norm > .ulpOfOne else { return }
        var scale = 1 / norm
        vDSP_vsmul(vector, 1, &scale, &vector, 1, vDSP_Length(vector.count))
    }
}

/// Bounded min-heap keyed by score: keeps the K highest-scoring elements
/// seen so far. Insert is O(log k); memory is O(k) regardless of corpus size.
nonisolated struct TopKHeap<Element> {
    private var heap: [(score: Float, element: Element)] = []
    let k: Int

    init(k: Int) {
        self.k = max(0, k)
        heap.reserveCapacity(self.k)
    }

    mutating func insert(_ element: Element, score: Float) {
        guard k > 0 else { return }
        if heap.count < k {
            heap.append((score, element))
            siftUp(from: heap.count - 1)
        } else if score > heap[0].score {
            heap[0] = (score, element)
            siftDown(from: 0)
        }
    }

    /// Highest score first.
    func sortedDescending() -> [(score: Float, element: Element)] {
        heap.sorted { $0.score > $1.score }
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].score < heap[parent].score else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, heap[left].score < heap[smallest].score {
                smallest = left
            }
            if right < heap.count, heap[right].score < heap[smallest].score {
                smallest = right
            }
            guard smallest != parent else { break }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
