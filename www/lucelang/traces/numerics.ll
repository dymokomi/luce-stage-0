; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/numerics.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/numerics.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.1 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.2 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.3 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.4 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce.text.5 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.6 = private unnamed_addr constant [6 x i8] c"square"
@luce.text.7 = private unnamed_addr constant [59 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/numerics.luc"
@luce.origins.0 = private constant [4 x { i32, i32 }] [{ i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }]
@luce.text.8 = private unnamed_addr constant [4 x i8] c"main"
@luce.origins.1 = private constant [12 x { i32, i32 }] [{ i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }]
@luce.functions = private constant [2 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.6, i64 6, ptr @luce.text.7, i64 59, ptr @luce.origins.0, i64 4 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.8, i64 4, ptr @luce.text.7, i64 59, ptr @luce.origins.1, i64 12 }]
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.square(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %4) {
5:
  %6 = alloca i64, align 8
  store i64 %3, ptr %6, align 8
  br label %7

7:
  %8 = load i64, ptr %6, align 8
  %9 = load i64, ptr %6, align 8
  %10 = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 %8, i64 %9)
  %11 = extractvalue { i64, i1 } %10, 0
  %12 = extractvalue { i64, i1 } %10, 1
  br i1 %12, label %13, label %16, !prof !0

13:
  %14 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 16 }, 0
  %15 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %14, i64 %15)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

16:
  store i64 %11, ptr %4, align 8
  ret i32 0
}

define internal i32 @luce.1.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  %7 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 0
  store i8 4, ptr %7, align 1
  %8 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 1
  store i8 -1, ptr %8, align 1
  %9 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 0 }, 0
  %10 = ptrtoint ptr %9 to i64
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 3
  store i64 %10, ptr %11, align 8
  %12 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 0 }, 1
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 4
  store i64 %12, ptr %13, align 8
  %14 = sub nsw i64 %2, 1
  %15 = alloca i64, align 8
  %16 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %16, i32 0, i32 0
  store i8 2, ptr %17, align 1
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %16, i32 0, i32 4
  store i64 0, ptr %18, align 8
  %19 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %20 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %21

21:
  %22 = load i64, ptr %5, align 8
  %23 = trunc i64 %22 to i32
  %24 = lshr i64 %22, 32
  %25 = trunc i64 %24 to i32
  %26 = icmp eq i32 %23, -1
  br i1 %26, label %27, label %30, !prof !0

27:
  %28 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 0
  %29 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %28, i64 %29)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

30:
  %31 = getelementptr inbounds i8, ptr %1, i64 96
  %32 = load ptr, ptr %31, align 8!alias.scope !1, !noalias !2
  %33 = zext i32 %23 to i64
  %34 = mul nsw i64 %33, 112
  %35 = getelementptr inbounds i8, ptr %32, i64 %34
  %36 = getelementptr inbounds i8, ptr %35, i64 96
  %37 = load i32, ptr %36, align 4, !alias.scope !1, !noalias !2
  %38 = icmp ne i32 %37, %25
  br i1 %38, label %39, label %42, !prof !0

39:
  %40 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %41 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %40, i64 %41)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

42:
  %43 = and i32 %37, 1
  %44 = icmp ne i32 %43, 0
  br i1 %44, label %45, label %48, !prof !0

45:
  %46 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %47 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %46, i64 %47)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

48:
  %49 = getelementptr inbounds i8, ptr %35, i64 16
  %50 = load i64, ptr %49, align 8!alias.scope !1, !noalias !2
  %51 = load ptr, ptr %35, align 8, !alias.scope !1, !noalias !2
  %52 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %50, i64 1)
  %53 = extractvalue { i64, i1 } %52, 0
  %54 = extractvalue { i64, i1 } %52, 1
  br i1 %54, label %55, label %58, !prof !0

55:
  %56 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 16 }, 0
  %57 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %56, i64 %57)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 3)
  ret i32 1

58:
  %59 = icmp slt i64 %14, 1
  br i1 %59, label %60, label %63, !prof !0

60:
  %61 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 19 }, 0
  %62 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %61, i64 %62)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 4)
  ret i32 1

63:
  %64 = call i32 @luce.0.square(ptr %0, ptr %1, i64 %14, i64 %53, ptr %15)
  %65 = icmp ne i32 %64, 0
  br i1 %65, label %66, label %67, !prof !0

66:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 4)
  ret i32 1

67:
  %68 = load i64, ptr %15, align 8
  %69 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %16, i32 0, i32 3
  store i64 %68, ptr %69, align 8
  %70 = call i32 @luce_rt_str(ptr %1, ptr %16, ptr %19)
  %71 = icmp ne i32 %70, 0
  br i1 %71, label %72, label %73, !prof !0

72:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 5)
  ret i32 1

73:
  %74 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 3
  %75 = load i64, ptr %74, align 8
  %76 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 1
  %77 = load i8, ptr %76, align 1
  %78 = icmp eq i8 %77, -1
  %79 = inttoptr i64 %75 to ptr
  %80 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 2
  %81 = select i1 %78, ptr %79, ptr %80
  %82 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 4
  %83 = load i64, ptr %82, align 8
  %84 = zext i8 %77 to i64
  %85 = select i1 %78, i64 %83, i64 %84
  %86 = insertvalue { ptr, i64 } poison, ptr %81, 0
  %87 = insertvalue { ptr, i64 } %86, i64 %85, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %6, ptr align 8 %19, i64 24, i1 false)
  %88 = extractvalue { ptr, i64 } %87, 0
  %89 = extractvalue { ptr, i64 } %87, 1
  %90 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %91 = load ptr, ptr %90, align 8
  %92 = icmp eq ptr %91, null
  br i1 %92, label %93, label %96, !prof !0

93:
  %94 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %95 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %94, i64 %95)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 7)
  ret i32 1

96:
  %97 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %98 = load ptr, ptr %97, align 8
  %99 = call i32 %91(ptr %98, ptr %88, i64 %89)
  %100 = icmp eq i32 %99, -1
  br i1 %100, label %101, label %102, !prof !0

101:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

102:
  %103 = icmp ne i32 %99, 0
  %104 = icmp ne i32 %99, 1
  %105 = and i1 %103, %104
  br i1 %105, label %106, label %109, !prof !0

106:
  %107 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %108 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %107, i64 %108)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 7)
  ret i32 1

109:
  %110 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 3
  %111 = load i64, ptr %110, align 8
  %112 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 1
  %113 = load i8, ptr %112, align 1
  %114 = icmp eq i8 %113, -1
  %115 = inttoptr i64 %111 to ptr
  %116 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 2
  %117 = select i1 %114, ptr %115, ptr %116
  %118 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 4
  %119 = load i64, ptr %118, align 8
  %120 = zext i8 %113 to i64
  %121 = select i1 %114, i64 %119, i64 %120
  %122 = insertvalue { ptr, i64 } poison, ptr %117, 0
  %123 = insertvalue { ptr, i64 } %122, i64 %121, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %6, ptr %20)
  %124 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 3
  %125 = load i64, ptr %124, align 8
  %126 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 1
  %127 = load i8, ptr %126, align 1
  %128 = icmp eq i8 %127, -1
  %129 = inttoptr i64 %125 to ptr
  %130 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 2
  %131 = select i1 %128, ptr %129, ptr %130
  %132 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 4
  %133 = load i64, ptr %132, align 8
  %134 = zext i8 %127 to i64
  %135 = select i1 %128, i64 %133, i64 %134
  %136 = insertvalue { ptr, i64 } poison, ptr %131, 0
  %137 = insertvalue { ptr, i64 } %136, i64 %135, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %6, ptr align 8 %20, i64 24, i1 false)
  ret i32 0
}

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64 %0, i64 %1) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #1

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #1

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %0, i64 %1) #0

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #2

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #3

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #4

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #5

define i32 @luce_main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0) {
1:
  %2 = alloca i64, align 8
  %3 = alloca i32, align 8
  store i64 256, ptr %2, align 8
  %4 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %5 = load ptr, ptr %4, align 8
  %6 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 14
  %7 = load ptr, ptr %6, align 8
  %8 = icmp eq ptr %7, null
  br i1 %8, label %11, label %9

9:
  %10 = call i64 %7(ptr %5)
  store i64 %10, ptr %2, align 8
  br label %11

11:
  %12 = load i64, ptr %2, align 8
  %13 = call ptr @luce_rt_open(ptr @luce.functions, i64 2)
  %14 = icmp eq ptr %13, null
  br i1 %14, label %15, label %16, !prof !0

15:
  ret i32 2

16:
  %17 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 28
  %18 = load ptr, ptr %17, align 8
  %19 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 54
  %20 = load ptr, ptr %19, align 8
  %21 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 55
  %22 = load ptr, ptr %21, align 8
  %23 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 56
  %24 = load ptr, ptr %23, align 8
  %25 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 57
  %26 = load ptr, ptr %25, align 8
  %27 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 58
  %28 = load ptr, ptr %27, align 8
  %29 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 29
  %30 = load ptr, ptr %29, align 8
  %31 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 30
  %32 = load ptr, ptr %31, align 8
  %33 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 31
  %34 = load ptr, ptr %33, align 8
  %35 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 32
  %36 = load ptr, ptr %35, align 8
  call void @luce_rt_files_install(ptr %13, ptr %5, ptr %18, ptr %20, ptr %22, ptr %24, ptr %26, ptr %28, ptr %30, ptr %32, ptr %34, ptr %36)
  %37 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 48
  %38 = load ptr, ptr %37, align 8
  %39 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 49
  %40 = load ptr, ptr %39, align 8
  %41 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 50
  %42 = load ptr, ptr %41, align 8
  %43 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 51
  %44 = load ptr, ptr %43, align 8
  %45 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 52
  %46 = load ptr, ptr %45, align 8
  call void @luce_rt_sockets_install(ptr %13, ptr %5, ptr %38, ptr %40, ptr %42, ptr %44, ptr %46)
  %47 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 40
  %48 = load ptr, ptr %47, align 8
  %49 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 41
  %50 = load ptr, ptr %49, align 8
  %51 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 42
  %52 = load ptr, ptr %51, align 8
  %53 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 43
  %54 = load ptr, ptr %53, align 8
  %55 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 44
  %56 = load ptr, ptr %55, align 8
  %57 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 45
  %58 = load ptr, ptr %57, align 8
  %59 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 46
  %60 = load ptr, ptr %59, align 8
  %61 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 47
  %62 = load ptr, ptr %61, align 8
  call void @luce_rt_graphics_install(ptr %13, ptr %5, ptr %48, ptr %50, ptr %52, ptr %54, ptr %56, ptr %58, ptr %60, ptr %62)
  %63 = icmp slt i64 %12, 1
  br i1 %63, label %64, label %65, !prof !0

64:
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.4, i64 19)
  store i32 1, ptr %3, align 8
  br label %73

65:
  %66 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %67 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 4
  %68 = load ptr, ptr %67, align 8
  %69 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 5
  %70 = load ptr, ptr %69, align 8
  %71 = call i32 @luce_rt_args_list(ptr %13, ptr %5, ptr %68, ptr %70, ptr %66)
  %72 = icmp ne i32 %71, 0
  br i1 %72, label %77, label %78, !prof !0

73:
  %74 = load i32, ptr %3, align 8
  %75 = icmp eq i32 %74, 1
  %76 = icmp eq i32 %74, 2
  br i1 %75, label %83, label %86, !prof !0

77:
  store i32 1, ptr %3, align 8
  br label %73

78:
  %79 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %66, i32 0, i32 3
  %80 = load i64, ptr %79, align 8
  %81 = call i32 @luce.1.main(ptr %0, ptr %13, i64 %12, i64 %80)
  store i32 %81, ptr %3, align 8
  %82 = call i32 @luce_rt_release(ptr %13, ptr %66)
  br label %73

83:
  %84 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 2
  %85 = load ptr, ptr %84, align 8
  call void @luce_rt_report(ptr %13, ptr %5, ptr %85)
  br label %86

86:
  br i1 %76, label %87, label %90, !prof !0

87:
  %88 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 15
  %89 = load ptr, ptr %88, align 8
  call void @luce_rt_report_error(ptr %13, ptr %5, ptr %89)
  br label %90

90:
  %91 = call i32 @luce_rt_status(ptr %13, i32 %74)
  %92 = icmp eq i32 %91, 2
  %93 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 3
  %94 = load ptr, ptr %93, align 8
  %95 = icmp eq ptr %94, null
  %96 = or i1 %95, %92
  br i1 %96, label %97, label %98

97:
  call void @luce_rt_close(ptr %13)
  ret i32 %91

98:
  %99 = call i64 @luce_rt_leaked(ptr %13)
  call void %94(ptr %5, i64 %99)
  br label %97
}

; Function Attrs: nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite)
declare noalias ptr @luce_rt_open(ptr readonly %0, i64 %1) #6

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_files_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9, ptr %10, ptr %11) #7

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #8

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #7

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #9

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #9

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #10

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #10

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #11

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #11

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #9

attributes #0 = { nounwind speculatable willreturn nofree nosync nocallback memory(none) }
attributes #1 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #2 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #3 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #4 = { nounwind cold willreturn memory(argmem: write) }
attributes #5 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #6 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #7 = { nounwind willreturn memory(argmem: readwrite) }
attributes #8 = { nounwind willreturn memory(readwrite) }
attributes #9 = { nounwind memory(readwrite) }
attributes #10 = { cold }
attributes #11 = { nounwind willreturn memory(argmem: read) }

!0 = !{!"branch_weights", i32 1, i32 2000}
!1 = !{!3}
!2 = !{!4}
!3 = !{!"luce.rows", !5}
!4 = !{!"luce.elements", !5}
!5 = !{!"luce.alias"}
