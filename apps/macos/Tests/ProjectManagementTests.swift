import XCTest
@testable import Clumsies

final class ProjectManagementTests: XCTestCase {
    func testProjectScopedAgentsExcludeGlobalCodexPlugin() {
        XCTAssertEqual(
            ProjectAgentAdapterKind.projectScopedCases,
            [.claudeCode, .opencode, .dsh, .antigravity]
        )
    }

    func testProjectMetadataRequiresANonEmptyName() {
        XCTAssertFalse(ProjectMetadataValidation.isValid(name: "   ", description: "Description"))
        XCTAssertTrue(ProjectMetadataValidation.isValid(name: " Project ", description: "Description"))
    }

    func testProjectMetadataEnforcesServerLimits() {
        XCTAssertTrue(
            ProjectMetadataValidation.isValid(
                name: String(repeating: "a", count: 120),
                description: String(repeating: "b", count: 4_000)
            )
        )
        XCTAssertFalse(
            ProjectMetadataValidation.isValid(
                name: String(repeating: "a", count: 121),
                description: ""
            )
        )
        XCTAssertFalse(
            ProjectMetadataValidation.isValid(
                name: "Project",
                description: String(repeating: "b", count: 4_001)
            )
        )
        XCTAssertTrue(
            ProjectMetadataValidation.isValid(
                name: "Project",
                description: " \(String(repeating: "b", count: 4_000)) "
            )
        )
    }

    func testDesktopProjectCreationRequiresALocalRepository() {
        XCTAssertFalse(
            ProjectCreationValidation.isValid(
                name: "Project",
                description: "",
                repositoryCount: 0
            )
        )
        XCTAssertTrue(
            ProjectCreationValidation.isValid(
                name: "Project",
                description: "",
                repositoryCount: 2
            )
        )
    }
}
