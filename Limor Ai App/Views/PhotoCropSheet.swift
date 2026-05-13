import SwiftUI
import UIKit

/// Lets the user position + zoom a photo before it's saved as the avatar.
/// PHPickerViewController doesn't expose any editing UI and SwiftUI has no
/// built-in cropper, so the old flow just center-cropped — which is fine
/// for landscape pets but routinely lopped the user's face off the side
/// of a portrait selfie. This sheet shows the photo with a circular
/// cut-out, lets the user drag + pinch into place, and renders the
/// visible square at output resolution.
struct PhotoCropSheet: View {
    let source: UIImage
    /// Side length of the rendered JPEG that lands in the avatar (px).
    /// 256 matches what we shipped before the cropper landed.
    var outputSide: CGFloat = 256
    var onCancel: () -> Void
    var onConfirm: (UIImage) -> Void

    @State private var userScale: CGFloat = 1
    @State private var lastUserScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Captured from the GeometryReader so `render()` knows what
    /// container the offset/scale gesture state is relative to.
    @State private var liveContainerSide: CGFloat = 0

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let containerSide = min(geo.size.width, geo.size.height) - 24
                let cropSide = containerSide * 0.86
                // Base scale that makes the image fully cover the container
                // (aspectFill). Larger of width-fit and height-fit so the
                // shorter image dimension reaches the container edge.
                let baseScale = max(
                    containerSide / source.size.width,
                    containerSide / source.size.height
                )
                let displayedW = source.size.width * baseScale
                let displayedH = source.size.height * baseScale
                // Don't let the user shrink the image below the crop circle.
                let minUserScale = cropSide / containerSide

                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: source)
                        .resizable()
                        .frame(width: displayedW, height: displayedH)
                        .scaleEffect(userScale)
                        .offset(offset)

                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .reverseMask {
                            Circle().frame(width: cropSide, height: cropSide)
                        }
                        .allowsHitTesting(false)

                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                        .frame(width: cropSide, height: cropSide)
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .onAppear { liveContainerSide = containerSide }
                .onChange(of: containerSide) { _, newValue in
                    liveContainerSide = newValue
                }
                .gesture(
                    SimultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                let next = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                                offset = clamp(
                                    offset: next,
                                    cropSide: cropSide,
                                    displayedW: displayedW,
                                    displayedH: displayedH,
                                    userScale: userScale
                                )
                            }
                            .onEnded { _ in lastOffset = offset },
                        MagnificationGesture()
                            .onChanged { value in
                                let next = max(minUserScale, lastUserScale * value)
                                userScale = next
                                offset = clamp(
                                    offset: offset,
                                    cropSide: cropSide,
                                    displayedW: displayedW,
                                    displayedH: displayedH,
                                    userScale: userScale
                                )
                            }
                            .onEnded { _ in
                                lastUserScale = userScale
                                lastOffset = offset
                            }
                    )
                )
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("מקם את התמונה")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("בטל") { onCancel() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("שמור") { onConfirm(render()) }
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .presentationDragIndicator(.hidden)
    }

    /// Clamp `offset` so the crop circle never escapes the displayed image
    /// rect at the current scale. The displayed image is centered at
    /// (0,0) before offset and has size (displayedW × userScale) by
    /// (displayedH × userScale) on screen.
    private func clamp(
        offset: CGSize,
        cropSide: CGFloat,
        displayedW: CGFloat,
        displayedH: CGFloat,
        userScale: CGFloat
    ) -> CGSize {
        let halfImageW = (displayedW * userScale) / 2
        let halfImageH = (displayedH * userScale) / 2
        let halfCrop = cropSide / 2
        let maxX = max(0, halfImageW - halfCrop)
        let maxY = max(0, halfImageH - halfCrop)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    /// Map current display-space gesture state to a source-pixel crop rect
    /// and rasterize it at `outputSide × outputSide`. `source` is assumed
    /// to already be in `.up` orientation — the caller is responsible for
    /// that (SettingsView normalizes before handing the image in), since
    /// pixel-space crop math wants the raw bitmap to match what's drawn.
    private func render() -> UIImage {
        let normalized = source
        // Use the live container size we captured from GeometryReader so
        // the math here matches what the user saw on screen.
        let containerSide = liveContainerSide > 0 ? liveContainerSide : 320
        let cropSide = containerSide * 0.86
        let baseScale = max(
            containerSide / normalized.size.width,
            containerSide / normalized.size.height
        )
        // Total scale from source pixels → screen points.
        let totalScale = baseScale * userScale
        // Crop side in source pixels.
        let sourceCropSide = cropSide / totalScale
        // The image is centered at the container center *before* offset.
        // A positive screen offset shifts the image down/right, which
        // means the crop window sees the *top/left* of the image. So we
        // subtract offset (in source pixels) from the source center.
        let dx = offset.width / totalScale
        let dy = offset.height / totalScale
        let cropRect = CGRect(
            x: normalized.size.width / 2 - sourceCropSide / 2 - dx,
            y: normalized.size.height / 2 - sourceCropSide / 2 - dy,
            width: sourceCropSide,
            height: sourceCropSide
        ).integral

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: outputSide, height: outputSide)
        )
        return renderer.image { _ in
            if let cg = normalized.cgImage?.cropping(to: cropRect) {
                UIImage(cgImage: cg, scale: 1, orientation: .up)
                    .draw(in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
            } else {
                normalized.draw(in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
            }
        }
    }
}

// MARK: - reverseMask helper

private extension View {
    /// Like `.mask` but uses the negative space — the masking shape is
    /// the *hole*, not the visible area. Used to dim the photo *outside*
    /// the crop circle while leaving the inside clear.
    @ViewBuilder
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(mask().blendMode(.destinationOut))
        }
    }
}
