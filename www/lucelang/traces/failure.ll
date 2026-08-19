; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/failure.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/failure.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [20 x i8] c"count cannot be zero"
@luce.text.1 = private unnamed_addr constant [16 x i8] c"division by zero"
@luce.text.2 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.3 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.4 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.5 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.6 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce.text.7 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.8 = private unnamed_addr constant [6 x i8] c"divide"
@luce.text.9 = private unnamed_addr constant [58 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/failure.luc"
@luce.origins.0 = private constant [11 x { i32, i32 }] [{ i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 3, i32 9 }, { i32, i32 } { i32 3, i32 9 }, { i32, i32 } { i32 3, i32 9 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }]
@luce.text.10 = private unnamed_addr constant [4 x i8] c"main"
@luce.origins.1 = private constant [24 x { i32, i32 }] [{ i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }]
@luce.functions = private constant [2 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.8, i64 6, ptr @luce.text.9, i64 58, ptr @luce.origins.0, i64 11 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.10, i64 4, ptr @luce.text.9, i64 58, ptr @luce.origins.1, i64 24 }]
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.divide(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3, i64 %4, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %5) {
6:
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  store i64 %3, ptr %7, align 8
  store i64 %4, ptr %8, align 8
  br label %9

9:
  %10 = load i64, ptr %8, align 8
  %11 = icmp eq i64 %10, 0
  br i1 %11, label %12, label %15

12:
  %13 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 20 }, 0
  %14 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 20 }, 1
  call void @luce_rt_raise_error(ptr %1, i32 1, ptr %13, i64 %14, i32 0, i32 5)
  store i64 0, ptr %5, align 8
  ret i32 2

15:
  %16 = load i64, ptr %7, align 8
  %17 = load i64, ptr %8, align 8
  %18 = icmp eq i64 %17, 0
  br i1 %18, label %19, label %22, !prof !0

19:
  %20 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 16 }, 0
  %21 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 1, ptr %20, i64 %21)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 9)
  ret i32 1

22:
  %23 = icmp eq i64 %16, -9223372036854775808
  %24 = icmp eq i64 %17, -1
  %25 = and i1 %23, %24
  br i1 %25, label %26, label %29, !prof !0

26:
  %27 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 16 }, 0
  %28 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %27, i64 %28)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 9)
  ret i32 1

29:
  %30 = sdiv i64 %16, %17
  %31 = srem i64 %16, %17
  %32 = icmp ne i64 %31, 0
  %33 = xor i64 %31, %17
  %34 = icmp slt i64 %33, 0
  %35 = and i1 %32, %34
  %36 = sub i64 %30, 1
  %37 = select i1 %35, i64 %36, i64 %30
  store i64 %37, ptr %5, align 8
  ret i32 0
}

define internal i32 @luce.1.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  %9 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  store i64 0, ptr %6, align 8
  store i64 0, ptr %7, align 8
  store i64 0, ptr %8, align 8
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 0
  store i8 4, ptr %10, align 1
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  store i8 -1, ptr %11, align 1
  %12 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 0 }, 0
  %13 = ptrtoint ptr %12 to i64
  %14 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  store i64 %13, ptr %14, align 8
  %15 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 0 }, 1
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  store i64 %15, ptr %16, align 8
  %17 = sub nsw i64 %2, 1
  %18 = alloca i64, align 8
  %19 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %20 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 0
  store i8 2, ptr %20, align 1
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 4
  store i64 0, ptr %21, align 8
  %22 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %23 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %24

24:
  %25 = load i64, ptr %5, align 8
  %26 = trunc i64 %25 to i32
  %27 = lshr i64 %25, 32
  %28 = trunc i64 %27 to i32
  %29 = icmp eq i32 %26, -1
  br i1 %29, label %39, label %42, !prof !0

30:
  call void @luce_rt_forget_error(ptr %1)
  store i64 -1, ptr %7, align 8
  br label %33

31:
  %32 = load i64, ptr %6, align 8
  store i64 %32, ptr %7, align 8
  br label %33

33:
  %34 = load i64, ptr %7, align 8
  store i64 %34, ptr %8, align 8
  %35 = load i64, ptr %8, align 8
  %36 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 3
  store i64 %35, ptr %36, align 8
  %37 = call i32 @luce_rt_str(ptr %1, ptr %19, ptr %22)
  %38 = icmp ne i32 %37, 0
  br i1 %38, label %75, label %76, !prof !0

39:
  %40 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 21 }, 0
  %41 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %40, i64 %41)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 2)
  ret i32 1

42:
  %43 = getelementptr inbounds i8, ptr %1, i64 96
  %44 = load ptr, ptr %43, align 8!alias.scope !1, !noalias !2
  %45 = zext i32 %26 to i64
  %46 = mul nsw i64 %45, 112
  %47 = getelementptr inbounds i8, ptr %44, i64 %46
  %48 = getelementptr inbounds i8, ptr %47, i64 96
  %49 = load i32, ptr %48, align 4, !alias.scope !1, !noalias !2
  %50 = icmp ne i32 %49, %28
  br i1 %50, label %51, label %54, !prof !0

51:
  %52 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 22 }, 0
  %53 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %52, i64 %53)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 2)
  ret i32 1

54:
  %55 = and i32 %49, 1
  %56 = icmp ne i32 %55, 0
  br i1 %56, label %57, label %60, !prof !0

57:
  %58 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 22 }, 0
  %59 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %58, i64 %59)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 2)
  ret i32 1

60:
  %61 = getelementptr inbounds i8, ptr %47, i64 16
  %62 = load i64, ptr %61, align 8!alias.scope !1, !noalias !2
  %63 = load ptr, ptr %47, align 8, !alias.scope !1, !noalias !2
  %64 = icmp slt i64 %17, 1
  br i1 %64, label %65, label %68, !prof !0

65:
  %66 = extractvalue { ptr, i64 } { ptr @luce.text.6, i64 19 }, 0
  %67 = extractvalue { ptr, i64 } { ptr @luce.text.6, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %66, i64 %67)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 3)
  ret i32 1

68:
  %69 = call i32 @luce.0.divide(ptr %0, ptr %1, i64 %17, i64 42, i64 %62, ptr %18)
  %70 = icmp eq i32 %69, 1
  br i1 %70, label %71, label %72, !prof !0

71:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 3)
  ret i32 1

72:
  %73 = load i64, ptr %18, align 8
  %74 = icmp eq i32 %69, 2
  store i64 %73, ptr %6, align 8
  br i1 %74, label %30, label %31

75:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 17)
  ret i32 1

76:
  %77 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 3
  %78 = load i64, ptr %77, align 8
  %79 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 1
  %80 = load i8, ptr %79, align 1
  %81 = icmp eq i8 %80, -1
  %82 = inttoptr i64 %78 to ptr
  %83 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 2
  %84 = select i1 %81, ptr %82, ptr %83
  %85 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 4
  %86 = load i64, ptr %85, align 8
  %87 = zext i8 %80 to i64
  %88 = select i1 %81, i64 %86, i64 %87
  %89 = insertvalue { ptr, i64 } poison, ptr %84, 0
  %90 = insertvalue { ptr, i64 } %89, i64 %88, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %22, i64 24, i1 false)
  %91 = extractvalue { ptr, i64 } %90, 0
  %92 = extractvalue { ptr, i64 } %90, 1
  %93 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %94 = load ptr, ptr %93, align 8
  %95 = icmp eq ptr %94, null
  br i1 %95, label %96, label %99, !prof !0

96:
  %97 = extractvalue { ptr, i64 } { ptr @luce.text.7, i64 24 }, 0
  %98 = extractvalue { ptr, i64 } { ptr @luce.text.7, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %97, i64 %98)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 19)
  ret i32 1

99:
  %100 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %101 = load ptr, ptr %100, align 8
  %102 = call i32 %94(ptr %101, ptr %91, i64 %92)
  %103 = icmp eq i32 %102, -1
  br i1 %103, label %104, label %105, !prof !0

104:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

105:
  %106 = icmp ne i32 %102, 0
  %107 = icmp ne i32 %102, 1
  %108 = and i1 %106, %107
  br i1 %108, label %109, label %112, !prof !0

109:
  %110 = extractvalue { ptr, i64 } { ptr @luce.text.7, i64 24 }, 0
  %111 = extractvalue { ptr, i64 } { ptr @luce.text.7, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %110, i64 %111)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 19)
  ret i32 1

112:
  %113 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %114 = load i64, ptr %113, align 8
  %115 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  %116 = load i8, ptr %115, align 1
  %117 = icmp eq i8 %116, -1
  %118 = inttoptr i64 %114 to ptr
  %119 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 2
  %120 = select i1 %117, ptr %118, ptr %119
  %121 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  %122 = load i64, ptr %121, align 8
  %123 = zext i8 %116 to i64
  %124 = select i1 %117, i64 %122, i64 %123
  %125 = insertvalue { ptr, i64 } poison, ptr %120, 0
  %126 = insertvalue { ptr, i64 } %125, i64 %124, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %9, ptr %23)
  %127 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 3
  %128 = load i64, ptr %127, align 8
  %129 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 1
  %130 = load i8, ptr %129, align 1
  %131 = icmp eq i8 %130, -1
  %132 = inttoptr i64 %128 to ptr
  %133 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 2
  %134 = select i1 %131, ptr %132, ptr %133
  %135 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 4
  %136 = load i64, ptr %135, align 8
  %137 = zext i8 %130 to i64
  %138 = select i1 %131, i64 %136, i64 %137
  %139 = insertvalue { ptr, i64 } poison, ptr %134, 0
  %140 = insertvalue { ptr, i64 } %139, i64 %138, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %23, i64 24, i1 false)
  ret i32 0
}

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise_error(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3, i32 %4, i32 %5) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #1

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #1

; Function Attrs: nounwind willreturn memory(argmem: write)
declare void @luce_rt_forget_error(ptr nocapture nonnull noundef %0) #2

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #4

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #5

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #0

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
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.6, i64 19)
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

attributes #0 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #1 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #2 = { nounwind willreturn memory(argmem: write) }
attributes #3 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #4 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #5 = { nounwind cold willreturn memory(argmem: write) }
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
