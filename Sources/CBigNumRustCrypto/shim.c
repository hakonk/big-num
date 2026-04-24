// This translation unit exists only so Swift Package Manager treats
// CBigNumRustCrypto as a buildable C target. All real symbols live in the
// Rust static library (`libbig_num_rustcrypto.a`) linked by the BigNum
// target's `linkerSettings`.
#include "CBigNumRustCrypto.h"
