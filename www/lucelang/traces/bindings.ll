; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/bindings.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/bindings.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.1 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.2 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.3 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.4 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.5 = private unnamed_addr constant [4 x i8] c"main"
@luce.text.6 = private unnamed_addr constant [59 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/bindings.luc"
@luce.origins.0 = private constant [17 x { i32, i32 }] [{ i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }]
@luce.functions = private constant [1 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.5, i64 4, ptr @luce.text.6, i64 59, ptr @luce.origins.0, i64 17 }]
@luce.text.7 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  store i64 0, ptr %6, align 8
  store i64 0, ptr %7, align 8
  %9 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 0
  store i8 4, ptr %9, align 1
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 1
  store i8 -1, ptr %10, align 1
  %11 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %12 = ptrtoint ptr %11 to i64
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  store i64 %12, ptr %13, align 8
  %14 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %15 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  store i64 %14, ptr %15, align 8
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
  %28 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %29 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %28, i64 %29)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
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
  %40 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %41 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %40, i64 %41)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

42:
  %43 = and i32 %37, 1
  %44 = icmp ne i32 %43, 0
  br i1 %44, label %45, label %48, !prof !0

45:
  %46 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %47 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %46, i64 %47)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

48:
  %49 = getelementptr inbounds i8, ptr %35, i64 16
  %50 = load i64, ptr %49, align 8!alias.scope !1, !noalias !2
  %51 = load ptr, ptr %35, align 8, !alias.scope !1, !noalias !2
  store i64 %50, ptr %6, align 8
  %52 = load i64, ptr %6, align 8
  %53 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %52, i64 2)
  %54 = extractvalue { i64, i1 } %53, 0
  %55 = extractvalue { i64, i1 } %53, 1
  br i1 %55, label %56, label %59, !prof !0

56:
  %57 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 16 }, 0
  %58 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %57, i64 %58)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 5)
  ret i32 1

59:
  store i64 %54, ptr %6, align 8
  %60 = load i64, ptr %6, align 8
  store i64 %60, ptr %7, align 8
  %61 = load i64, ptr %7, align 8
  %62 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %16, i32 0, i32 3
  store i64 %61, ptr %62, align 8
  %63 = call i32 @luce_rt_str(ptr %1, ptr %16, ptr %19)
  %64 = icmp ne i32 %63, 0
  br i1 %64, label %65, label %66, !prof !0

65:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 10)
  ret i32 1

66:
  %67 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 3
  %68 = load i64, ptr %67, align 8
  %69 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 1
  %70 = load i8, ptr %69, align 1
  %71 = icmp eq i8 %70, -1
  %72 = inttoptr i64 %68 to ptr
  %73 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 2
  %74 = select i1 %71, ptr %72, ptr %73
  %75 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 4
  %76 = load i64, ptr %75, align 8
  %77 = zext i8 %70 to i64
  %78 = select i1 %71, i64 %76, i64 %77
  %79 = insertvalue { ptr, i64 } poison, ptr %74, 0
  %80 = insertvalue { ptr, i64 } %79, i64 %78, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %19, i64 24, i1 false)
  %81 = extractvalue { ptr, i64 } %80, 0
  %82 = extractvalue { ptr, i64 } %80, 1
  %83 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %84 = load ptr, ptr %83, align 8
  %85 = icmp eq ptr %84, null
  br i1 %85, label %86, label %89, !prof !0

86:
  %87 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %88 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %87, i64 %88)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 12)
  ret i32 1

89:
  %90 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %91 = load ptr, ptr %90, align 8
  %92 = call i32 %84(ptr %91, ptr %81, i64 %82)
  %93 = icmp eq i32 %92, -1
  br i1 %93, label %94, label %95, !prof !0

94:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

95:
  %96 = icmp ne i32 %92, 0
  %97 = icmp ne i32 %92, 1
  %98 = and i1 %96, %97
  br i1 %98, label %99, label %102, !prof !0

99:
  %100 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %101 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %100, i64 %101)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 12)
  ret i32 1

102:
  %103 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  %104 = load i64, ptr %103, align 8
  %105 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 1
  %106 = load i8, ptr %105, align 1
  %107 = icmp eq i8 %106, -1
  %108 = inttoptr i64 %104 to ptr
  %109 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 2
  %110 = select i1 %107, ptr %108, ptr %109
  %111 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  %112 = load i64, ptr %111, align 8
  %113 = zext i8 %106 to i64
  %114 = select i1 %107, i64 %112, i64 %113
  %115 = insertvalue { ptr, i64 } poison, ptr %110, 0
  %116 = insertvalue { ptr, i64 } %115, i64 %114, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %8, ptr %20)
  %117 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 3
  %118 = load i64, ptr %117, align 8
  %119 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 1
  %120 = load i8, ptr %119, align 1
  %121 = icmp eq i8 %120, -1
  %122 = inttoptr i64 %118 to ptr
  %123 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 2
  %124 = select i1 %121, ptr %122, ptr %123
  %125 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 4
  %126 = load i64, ptr %125, align 8
  %127 = zext i8 %120 to i64
  %128 = select i1 %121, i64 %126, i64 %127
  %129 = insertvalue { ptr, i64 } poison, ptr %124, 0
  %130 = insertvalue { ptr, i64 } %129, i64 %128, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %20, i64 24, i1 false)
  ret i32 0
}

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #0

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %0, i64 %1) #1

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
  %13 = call ptr @luce_rt_open(ptr @luce.functions, i64 1)
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
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.7, i64 19)
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
  %81 = call i32 @luce.0.main(ptr %0, ptr %13, i64 %12, i64 %80)
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

attributes #0 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #1 = { nounwind speculatable willreturn nofree nosync nocallback memory(none) }
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
