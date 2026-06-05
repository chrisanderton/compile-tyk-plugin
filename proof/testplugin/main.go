package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"
import (
	"fmt"
	"unsafe"
)

// Exported function -> forces a real -buildmode=plugin shared object,
// and the cgo malloc/memset force a genuine libc (glibc) link.
func Foo() string {
	p := C.malloc(16)
	defer C.free(p)
	C.memset(p, 0, 16)
	return fmt.Sprintf("ok:%v", unsafe.Pointer(p))
}

func main() {}
