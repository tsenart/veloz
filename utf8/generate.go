//go:generate go run github.com/mhr3/goruntool@v0.1.1 github.com/mhr3/gocc/cmd/gocc@v0.16.3 csrc/range_avx2.c -l -p utf8 -o ./ -a avx2 -O3
//go:generate go run github.com/mhr3/goruntool@v0.1.1 github.com/mhr3/gocc/cmd/gocc@v0.16.3 csrc/range_neon.c -l -p utf8 -o ./ -a arm64 -O3

package utf8
