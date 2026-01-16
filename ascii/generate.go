//go:generate go run github.com/mhr3/goruntool@v0.1.1 github.com/tsenart/gocc/cmd/gocc@fix-arm64-stack-transform csrc/ascii_sse.c -l -p ascii -o ./ -a amd64 -O3 -msse4.1
//go:generate go run github.com/mhr3/goruntool@v0.1.1 github.com/tsenart/gocc/cmd/gocc@fix-arm64-stack-transform csrc/ascii_avx2.c -l -p ascii -o ./ -a avx2 -O3
//go:generate env CC=/opt/homebrew/opt/llvm/bin/clang go run github.com/mhr3/goruntool@v0.1.1 github.com/tsenart/gocc/cmd/gocc@fix-arm64-stack-transform csrc/ascii_neon.c -l -p ascii -o ./ -a arm64 -O3

package ascii
