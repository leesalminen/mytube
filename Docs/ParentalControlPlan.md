# Parental Review Controls Implementation

## Core Data Schema Changes

**File:** `MyTube/MyTube.xcdatamodeld/MyTube.xcdatamodel/contents`

Add to Video entity:

- `approvalStatus` (String, default "approved") - values: "approved", "pending", "rejected", "scanning"
- `approvedAt` (Date, optional)
- `approvedByParentKey` (String, optional)
- `scanResults` (String, optional) - JSON with scan metadata
- `scanCompletedAt` (Date, optional)

**Migration:** Existing videos default to "approved" status (no behavior change for existing content).

## New Service: ParentalControlsStore

**File:** `MyTube/Services/ParentalControlsStore.swift`

Store parent preferences in UserDefaults:

- `requiresVideoApproval: Bool` (default: false)
- `enableContentScanning: Bool` (default: true)
- `autoRejectThreshold: Double?` (optional, 0.0-1.0, nil = never auto-reject)

Similar pattern to `SafetyConfigurationStore.swift`.

## New Service: VideoContentScanner

**File:** `MyTube/Services/Safety/VideoContentScanner.swift`

Implements multi-layer scanning:

**Layer 1: Vision Framework** (~500ms for 10 frames)

- `VNClassifyImageRequest` for scene classification
- `VNRecognizeTextRequest` for profanity in text
- `VNDetectHumanBodyPoseRequest` for pose analysis
- Sample 10 frames evenly throughout video

**Layer 2: Core ML NSFW Model** (~200ms per frame, 5 frames)

- Bundle GantMan's NSFW model (converted to Core ML, ~17MB)
- Only runs if Vision results are uncertain
- Returns confidence score 0.0-1.0

**Output:** `ContentScanResult`

- `isSafe: Bool`
- `confidence: Double`
- `flaggedReasons: [String]`
- `scannedFrameCount: Int`

## Update Domain Models

**File:** `MyTube/Domain/Models.swift`

Add to `VideoModel`:

```swift
enum ApprovalStatus: String {
    case scanning, pending, approved, rejected
}

var approvalStatus: ApprovalStatus
var approvedAt: Date?
var approvedByParentKey: String?
var scanResults: String?  // JSON metadata
var scanCompletedAt: Date?

var needsApproval: Bool {
    approvalStatus == .pending
}
```

## Update VideoLibrary Service

**File:** `MyTube/Services/VideoLibrary.swift`

Modify `createVideo(request:)`:

1. Create video entity with `approvalStatus = "scanning"`
2. Save to Core Data (triggers UI update showing "Scanning...")
3. Run `VideoContentScanner.scan(url:)` async
4. Update entity with scan results
5. Set `approvalStatus` based on:

   - If `requiresVideoApproval == false`: set to "approved"
   - If scan confidence < threshold: set to "pending"
   - Otherwise: set to "approved"

6. Save again (triggers share coordinator if approved)

Add method: `thumbnailFileURL(for: VideoModel) -> URL` (for HomeFeed).

## Update VideoShareCoordinator

**File:** `MyTube/Services/VideoShareCoordinator.swift`

Modify `processVideo(objectID:)`:

- Check `parentalControlsStore.requiresVideoApproval`
- Only proceed if `video.approvalStatus == .approved`
- Log info when video awaits approval

Add new method: `publishVideo(_ videoId: UUID) async throws`

- Validates video exists and is pending
- Marks video as approved with parent key and timestamp
- Triggers normal share flow
- Throws errors for missing video or invalid state

Add helper: `markVideoAsApproved(videoId: UUID, parentKey: String) async throws`

## Update Capture Flow

**File:** `MyTube/Features/Capture/CaptureViewModel.swift`

Modify `handleRecordingCompletion(at:)`:

- Show scanning indicator while `videoLibrary.createVideo()` runs
- Add `@Published var isScanning = false`
- Add `@Published var scanProgress: String?` (e.g., "Scanning frame 5/10...")
- Keep "Saved!" banner only after scan completes

## Update Editor Flow

**File:** `MyTube/Features/Editor/EditorDetailViewModel.swift`

Modify `exportEdit()`:

- Add `@Published var isScanning = false`
- Add `@Published var scanProgress: String?`
- Show scanning UI after export, before success banner

## New UI Component: PINPromptView

**File:** `MyTube/SharedUI/Components/PINPromptView.swift`

Reusable sheet for PIN entry:

- 4-digit numeric keypad
- Validates against `ParentAuth`
- Calls success/failure callbacks
- Auto-dismisses on success
- Shows error for invalid PIN
```swift
struct PINPromptView: View {
    let title: String
    let onSuccess: (String) async throws -> Void
    @Environment(\.dismiss) var dismiss
}
```


## Update HomeFeed UI

**File:** `MyTube/Features/HomeFeed/HomeFeedView.swift`

Modify `VideoCard` (line 287-341):

- Add overlay badge for pending videos (orange "Needs Approval" pill)
- Add "Publish to Family" button below thumbnail for pending videos
- Button triggers PIN prompt sheet

Add state:

```swift
@State private var videoToPublish: VideoModel?
@State private var showingPINPrompt = false
```

Add sheet for PIN prompt (line 47 area):

```swift
.sheet(isPresented: $showingPINPrompt) {
    if let video = videoToPublish {
        PINPromptView(title: "Publish Video") { pin in
            try await viewModel.publishVideo(video.id, pin: pin)
        }
    }
}
```

## Update HomeFeed ViewModel

**File:** `MyTube/Features/HomeFeed/HomeFeedViewModel.swift`

Add properties:

- `@Published var publishingVideoIds: Set<UUID> = []`
- Reference to `parentalControlsStore`

Add method:

```swift
func publishVideo(_ videoId: UUID, pin: String) async throws {
    guard try parentAuth.validate(pin: pin) else {
        throw ParentAuthError.invalidPIN
    }
    
    publishingVideoIds.insert(videoId)
    defer { publishingVideoIds.remove(videoId) }
    
    try await environment.videoShareCoordinator.publishVideo(videoId)
}
```

## Update ParentZone Settings

**File:** `MyTube/Features/ParentZone/ParentZoneView.swift`

Add new section "Content Controls" with:

- Toggle: "Require Approval Before Sharing"
- Toggle: "Enable Content Scanning" (always on if approval enabled)
- Text: explanation of feature
- Navigation link to "Pending Approval" list (if any pending videos)

Location: After storage/relay sections, before diagnostics.

## Update ParentZone ViewModel

**File:** `MyTube/Features/ParentZone/ParentZoneViewModel.swift`

Add properties:

- `@Published var requiresVideoApproval: Bool = false`
- `@Published var enableContentScanning: Bool = true`
- `@Published var pendingApprovalVideos: [VideoModel] = []`

Add methods:

- `loadParentalControls()` - reads from `ParentalControlsStore`
- `updateApprovalRequirement(_ enabled: Bool)` - saves to store
- `loadPendingApprovals()` - fetches videos with `approvalStatus == "pending"`
- `refreshPendingApprovals()` - called when returning to ParentZone

## Update AppEnvironment

**File:** `MyTube/AppEnvironment.swift`

Add properties:

```swift
let parentalControlsStore: ParentalControlsStore
let videoContentScanner: VideoContentScanner
```

Wire up in `live()` initializer (line 173+):

```swift
let parentalControlsStore = ParentalControlsStore()
let videoContentScanner = VideoContentScanner()
```

Pass to dependent services:

- `VideoLibrary` needs `parentalControlsStore` and `videoContentScanner`
- `VideoShareCoordinator` needs `parentalControlsStore`

## Core ML Model Integration

**File:** `MyTube/Resources/Models/NSFWDetector.mlmodel`

1. Download GantMan's NSFW model
2. Convert to Core ML using coremltools
3. Add to Xcode project under Resources/Models/
4. Ensure it's added to app target
5. Xcode generates `NSFWDetector` Swift class automatically

Reference in `VideoContentScanner` via:

```swift
let model = try NSFWDetector(configuration: .init())
```

## Testing Checklist

1. New video with approval OFF: scans → auto-publishes
2. New video with approval ON: scans → waits for PIN → publishes
3. Scanning UI appears during capture/export
4. Invalid PIN shows error
5. Pending videos show badge in HomeFeed
6. Publish button appears only for pending videos
7. Core Data migration handles existing videos
8. Content scanner flags test images correctly
9. Performance: scanning completes within 2 seconds
10. App size increase: ~17-20MB for Core ML model
