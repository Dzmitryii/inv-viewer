import Foundation

enum DemoStudy {
    static func arches(at url: URL, for volume: Volume) throws -> StudyArches {
        let arches = try JSONDecoder().decode(StudyArches.self, from: Data(contentsOf: url))
        guard arches.upper != nil, arches.lower != nil, arches.valid(in: volume) else {
            throw StudyStoreError.invalid
        }
        return arches
    }
}
