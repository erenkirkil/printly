/// How a greyscale image is reduced to the printer's one bit per dot.
///
/// Thermal heads have no grey: a dot is burned or it is not. The choice here is
/// what to do with everything in between.
///
/// Deliberately two values, not three. A `none` mode would have to pick some
/// cutoff anyway, making it byte-for-byte identical to [threshold] — an option
/// that promises a third behaviour it cannot deliver.
enum PrintlyDithering {
  /// Diffuses each pixel's quantisation error into its neighbours, trading
  /// spatial resolution for apparent greys. The right choice for photographs
  /// and gradients; on anti-aliased text at 203 dpi it produces speckle.
  floydSteinberg,

  /// Burns a dot when the pixel is darker than the cutoff, nothing else.
  /// Crisp and predictable — the right choice for text and line art.
  threshold,
}
