import ScreenObject
import XCTest

public class BlockEditorScreen: ScreenObject {

    let editorCloseButtonGetter: (XCUIApplication) -> XCUIElement = {
        $0.navigationBars["Gutenberg Editor Navigation Bar"].buttons["Close"]
    }

    var editorCloseButton: XCUIElement { editorCloseButtonGetter(app) }

    let addBlockButtonGetter: (XCUIApplication) -> XCUIElement = {
        $0.buttons["add-block-button"] // Uses a testID
    }

    var addBlockButton: XCUIElement { addBlockButtonGetter(app) }

    public init(app: XCUIApplication = XCUIApplication()) throws {
        // The block editor has _many_ elements but most are loaded on-demand. To verify the screen
        // is loaded, we rely only on the button to add a new block and on the navigation bar we
        // expect to encase the screen.
        try super.init(
            expectedElementGetters: [ addBlockButtonGetter, editorCloseButtonGetter ],
            app: app
        )
    }

    /**
     Enters text into title field.
     - Parameter text: the test to enter into the title
     */
    public func enterTextInTitle(text: String) -> BlockEditorScreen {
        let titleView = app.otherElements["Post title. Empty"].firstMatch // Uses a localized string

        titleView.tap()
        titleView.typeText(text)

        return self
    }

    /**
    Adds a paragraph block with text.
     - Parameter withText: the text to enter in the paragraph block
     */
    public func addParagraphBlock(withText text: String) -> BlockEditorScreen {
        addBlock("Paragraph block")

        let paragraphView = app.otherElements["Paragraph Block. Row 1. Empty"].textViews.element(boundBy: 0)
        paragraphView.typeText(text)

        return self
    }

    /**
     Adds an image block with latest image from device.
     */
    public func addImage() throws -> BlockEditorScreen {
        addBlock("Image block")
        try addImageByOrder(id: 0)

        return self
    }

    /**
    Selects a block based on part of the block label (e.g. partial text in a paragraph block)
     */
    @discardableResult
    public func selectBlock(containingText text: String) -> BlockEditorScreen {
        let predicate = NSPredicate(format: "label CONTAINS[c] '\(text)'")
        XCUIApplication().buttons.containing(predicate).firstMatch.tap()
        return self
    }

    // returns void since return screen depends on from which screen it loaded
    public func closeEditor() {
        XCTContext.runActivity(named: "Close the block editor") { (activity) in
            XCTContext.runActivity(named: "Close the More menu if needed") { (activity) in
                let actionSheet = app.sheets.element(boundBy: 0)
                if actionSheet.exists {
                    if XCUIDevice.isPad {
                        app.otherElements["PopoverDismissRegion"].tap()
                    } else {
                        let keepEditingButton = app.sheets.buttons["Keep Editing"] // Uses a localized string
                        keepEditingButton.tap()
                    }
                }
            }

            // Wait for close button to be hittable (i.e. React "Loading from pre-bundled file" message is gone)
            editorCloseButton.waitForIsHittable(timeout: 3)
            editorCloseButton.tap()

            XCTContext.runActivity(named: "Discard any local changes") { (activity) in
                let notSavedState = app.staticTexts["You have unsaved changes."]
                if notSavedState.exists {
                    Logger.log(message: "Discarding unsaved changes", event: .v)
                    let discardButton = app.buttons["Discard"] // Uses a localized string
                    discardButton.tap()
                }
            }

            let editorNavBar = app.navigationBars["Gutenberg Editor Navigation Bar"]
            let waitForEditorToClose = editorNavBar.waitFor(predicateString: "isEnabled == false")
            XCTAssertEqual(waitForEditorToClose, .completed, "Block editor should be closed but is still loaded.")
        }
    }

    public func publish() throws -> EditorNoticeComponent {
        let publishButton = app.buttons["Publish"]
        publishButton.tap()
        try confirmPublish()

        return try EditorNoticeComponent(withNotice: "Post published", andAction: "View")
    }

    public func openPostSettings() throws -> EditorPostSettings {
        let moreButton = app.buttons["more_post_options"]
        moreButton.tap()
        let postSettingsButton = app.sheets.buttons["Post Settings"] // Uses a localized string
        postSettingsButton.tap()

        return try EditorPostSettings()
    }

    private func addBlock(_ blockLabel: String) {
        addBlockButton.tap()
        XCUIApplication().buttons[blockLabel].tap()
    }

    /*
     Select Image from Camera Roll by its ID. Starts with 0
     */
    private func addImageByOrder(id: Int) throws {
        let imageDeviceButton = app.sheets.buttons["Choose from device"] // Uses a localized string

        imageDeviceButton.tap()

        // Allow access to device media
        app.tap() // trigger the media permissions alert handler

        // Inject the first picture
        try MediaPickerAlbumListScreen()
            .selectAlbum(atIndex: 0)
            .selectImage(atIndex: 0)
    }

    private func confirmPublish() throws {
        if FancyAlertComponent.isLoaded() {
            try FancyAlertComponent().acceptAlert()
        } else {
            let publishNowButton = app.buttons["Publish Now"]
            publishNowButton.tap()
        }
    }

    static func isLoaded() -> Bool {
        (try? BlockEditorScreen().isLoaded) ?? false
    }

    @discardableResult
    public func openBlockPicker() throws -> BlockEditorScreen {
        addBlockButton.tap()
        return try BlockEditorScreen()
    }

    @discardableResult
    public func closeBlockPicker() throws -> BlockEditorScreen {
        editorCloseButton.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).tap()
        return try BlockEditorScreen()
    }
}

// TODO: Move this to XCUITestHelpers or ScreenObject
extension XCUIElement {

    func waitFor(
        predicateString: String,
        timeout: TimeInterval = 10
    ) -> XCTWaiter.Result {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: predicateString),
                    object: self
                )
            ],
            timeout: timeout
        )
    }
}
