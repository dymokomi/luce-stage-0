; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/interfaces.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/interfaces.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.interface_witness_layouts = private constant [1 x i32] [i32 1]
@luce.interface_witness_offsets = private constant [1 x i32] zeroinitializer
@luce.interface_witness_methods = private constant [1 x i32] [i32 2]
@luce.function_table = private constant [3 x ptr] [ptr null, ptr null, ptr @luce.bound.2]
@luce.text.1 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce.text.2 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.3 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.4 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.5 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.6 = private unnamed_addr constant [4 x i8] c"read"
@luce.text.7 = private unnamed_addr constant [61 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/interfaces.luc"
@luce.origins.0 = private constant [3 x { i32, i32 }] [{ i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }]
@luce.text.8 = private unnamed_addr constant [4 x i8] c"main"
@luce.origins.1 = private constant [26 x { i32, i32 }] [{ i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }, { i32, i32 } { i32 15, i32 5 }]
@luce.text.9 = private unnamed_addr constant [13 x i8] c"Width.measure"
@luce.origins.2 = private constant [3 x { i32, i32 }] [{ i32, i32 } { i32 8, i32 9 }, { i32, i32 } { i32 8, i32 9 }, { i32, i32 } { i32 8, i32 9 }]
@luce.functions = private constant [3 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.6, i64 4, ptr @luce.text.7, i64 61, ptr @luce.origins.0, i64 3 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.8, i64 4, ptr @luce.text.7, i64 61, ptr @luce.origins.1, i64 26 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.9, i64 13, ptr @luce.text.7, i64 61, ptr @luce.origins.2, i64 3 }]
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.read(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, ptr align 8 readonly nonnull noundef %3, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %4) {
5:
  %6 = alloca ptr, align 8
  store ptr %3, ptr %6, align 8
  %7 = sub nsw i64 %2, 1
  %8 = alloca i64, align 8
  br label %9

9:
  %10 = load ptr, ptr %6, align 8
  %11 = ptrtoint ptr %10 to i64
  %12 = icmp eq i64 %11, 0
  br i1 %12, label %13, label %16, !prof !0

13:
  %14 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 0
  %15 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %14, i64 %15)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

16:
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i64 0
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 3
  %19 = load i64, ptr %18, align 8
  %20 = icmp ult i64 %19, 1
  br i1 %20, label %21, label %24, !prof !0

21:
  %22 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 0
  %23 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %22, i64 %23)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

24:
  %25 = icmp ugt i64 %19, 1
  br i1 %25, label %26, label %29, !prof !0

26:
  %27 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 0
  %28 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %27, i64 %28)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

29:
  %30 = sub i64 %19, 1
  %31 = getelementptr inbounds i32, ptr @luce.interface_witness_layouts, i64 %30
  %32 = load i32, ptr %31, align 4
  %33 = icmp ne i32 %32, 1
  br i1 %33, label %34, label %37, !prof !0

34:
  %35 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 0
  %36 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %35, i64 %36)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

37:
  %38 = getelementptr inbounds i32, ptr @luce.interface_witness_offsets, i64 %30
  %39 = load i32, ptr %38, align 4
  %40 = add i32 %39, 0
  %41 = zext i32 %40 to i64
  %42 = getelementptr inbounds i32, ptr @luce.interface_witness_methods, i64 %41
  %43 = load i32, ptr %42, align 4
  %44 = zext i32 %43 to i64
  %45 = getelementptr inbounds ptr, ptr @luce.function_table, i64 %44
  %46 = load ptr, ptr %45, align 8
  %47 = icmp slt i64 %7, 1
  br i1 %47, label %48, label %51, !prof !0

48:
  %49 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 19 }, 0
  %50 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %49, i64 %50)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

51:
  %52 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i64 1
  %53 = call i32 %46(ptr %0, ptr %1, i64 %7, ptr %52, ptr %8)
  %54 = icmp ne i32 %53, 0
  br i1 %54, label %55, label %56, !prof !0

55:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

56:
  %57 = load i64, ptr %8, align 8
  store i64 %57, ptr %4, align 8
  ret i32 0
}

define internal i32 @luce.1.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %7 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %8 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %9 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 0
  store i8 5, ptr %10, align 1
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 4
  store i64 1, ptr %11, align 8
  %12 = ptrtoint ptr null to i64
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 3
  store i64 %12, ptr %13, align 8
  %14 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 0
  store i8 5, ptr %14, align 1
  %15 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  store i64 1, ptr %15, align 8
  %16 = ptrtoint ptr null to i64
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  store i64 %16, ptr %17, align 8
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 0
  store i8 5, ptr %18, align 1
  %19 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  store i64 2, ptr %19, align 8
  %20 = ptrtoint ptr null to i64
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  store i64 %20, ptr %21, align 8
  %22 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 0
  store i8 4, ptr %22, align 1
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  store i8 -1, ptr %23, align 1
  %24 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 0 }, 0
  %25 = ptrtoint ptr %24 to i64
  %26 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  store i64 %25, ptr %26, align 8
  %27 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 0 }, 1
  %28 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  store i64 %27, ptr %28, align 8
  %29 = alloca { i8, i8, [6 x i8], i64, i64 },i64 1, align 8
  %30 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %29, i64 0
  %31 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 0
  store i8 2, ptr %31, align 1
  %32 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 4
  store i64 0, ptr %32, align 8
  %33 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %34 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %35 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %34, i32 0, i32 0
  store i8 5, ptr %35, align 1
  %36 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %34, i32 0, i32 4
  store i64 1, ptr %36, align 8
  %37 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %38 = alloca { i8, i8, [6 x i8], i64, i64 },i64 2, align 8
  %39 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i64 0
  %40 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 0
  store i8 2, ptr %40, align 1
  %41 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 4
  store i64 0, ptr %41, align 8
  %42 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i64 1
  %43 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %44 = sub nsw i64 %2, 1
  %45 = alloca i64, align 8
  %46 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %47 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %46, i32 0, i32 0
  store i8 2, ptr %47, align 1
  %48 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %46, i32 0, i32 4
  store i64 0, ptr %48, align 8
  %49 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %50 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %51 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %52 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %51, i32 0, i32 0
  store i8 5, ptr %52, align 1
  %53 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %51, i32 0, i32 4
  store i64 2, ptr %53, align 8
  %54 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %55 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %56

56:
  %57 = load i64, ptr %5, align 8
  %58 = trunc i64 %57 to i32
  %59 = lshr i64 %57, 32
  %60 = trunc i64 %59 to i32
  %61 = icmp eq i32 %58, -1
  br i1 %61, label %62, label %65, !prof !0

62:
  %63 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 0
  %64 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %63, i64 %64)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

65:
  %66 = getelementptr inbounds i8, ptr %1, i64 96
  %67 = load ptr, ptr %66, align 8!alias.scope !1, !noalias !2
  %68 = zext i32 %58 to i64
  %69 = mul nsw i64 %68, 112
  %70 = getelementptr inbounds i8, ptr %67, i64 %69
  %71 = getelementptr inbounds i8, ptr %70, i64 96
  %72 = load i32, ptr %71, align 4, !alias.scope !1, !noalias !2
  %73 = icmp ne i32 %72, %60
  br i1 %73, label %74, label %77, !prof !0

74:
  %75 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %76 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %75, i64 %76)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

77:
  %78 = and i32 %72, 1
  %79 = icmp ne i32 %78, 0
  br i1 %79, label %80, label %83, !prof !0

80:
  %81 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %82 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %81, i64 %82)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

83:
  %84 = getelementptr inbounds i8, ptr %70, i64 16
  %85 = load i64, ptr %84, align 8!alias.scope !1, !noalias !2
  %86 = load ptr, ptr %70, align 8, !alias.scope !1, !noalias !2
  %87 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %85, i64 4)
  %88 = extractvalue { i64, i1 } %87, 0
  %89 = extractvalue { i64, i1 } %87, 1
  br i1 %89, label %90, label %93, !prof !0

90:
  %91 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 0
  %92 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %91, i64 %92)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 3)
  ret i32 1

93:
  %94 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 3
  store i64 %88, ptr %94, align 8
  %95 = call i32 @luce_rt_struct_make(ptr %1, ptr %29, i64 1, ptr %33)
  %96 = icmp ne i32 %95, 0
  br i1 %96, label %97, label %98, !prof !0

97:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 4)
  ret i32 1

98:
  %99 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %33, i32 0, i32 3
  %100 = load i64, ptr %99, align 8
  %101 = inttoptr i64 %100 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %7, ptr align 8 %33, i64 24, i1 false)
  %102 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %103 = load i64, ptr %102, align 8
  %104 = inttoptr i64 %103 to ptr
  %105 = ptrtoint ptr %104 to i64
  %106 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %34, i32 0, i32 3
  store i64 %105, ptr %106, align 8
  %107 = call i32 @luce_rt_own_storage(ptr %1, ptr %34, ptr %37)
  %108 = icmp ne i32 %107, 0
  br i1 %108, label %109, label %110, !prof !0

109:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 7)
  ret i32 1

110:
  %111 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %37, i32 0, i32 3
  %112 = load i64, ptr %111, align 8
  %113 = inttoptr i64 %112 to ptr
  %114 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 3
  store i64 1, ptr %114, align 8
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %42, ptr align 8 %37, i64 24, i1 false)
  %115 = call i32 @luce_rt_struct_make(ptr %1, ptr %38, i64 2, ptr %43)
  %116 = icmp ne i32 %115, 0
  br i1 %116, label %117, label %118, !prof !0

117:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 8)
  ret i32 1

118:
  %119 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %43, i32 0, i32 3
  %120 = load i64, ptr %119, align 8
  %121 = inttoptr i64 %120 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %43, i64 24, i1 false)
  %122 = icmp slt i64 %44, 1
  br i1 %122, label %123, label %126, !prof !0

123:
  %124 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 19 }, 0
  %125 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %124, i64 %125)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 10)
  ret i32 1

126:
  %127 = call i32 @luce.0.read(ptr %0, ptr %1, i64 %44, ptr %121, ptr %45)
  %128 = icmp ne i32 %127, 0
  br i1 %128, label %129, label %130, !prof !0

129:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 10)
  ret i32 1

130:
  %131 = load i64, ptr %45, align 8
  %132 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %46, i32 0, i32 3
  store i64 %131, ptr %132, align 8
  %133 = call i32 @luce_rt_str(ptr %1, ptr %46, ptr %49)
  %134 = icmp ne i32 %133, 0
  br i1 %134, label %135, label %136, !prof !0

135:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 11)
  ret i32 1

136:
  %137 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %49, i32 0, i32 3
  %138 = load i64, ptr %137, align 8
  %139 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %49, i32 0, i32 1
  %140 = load i8, ptr %139, align 1
  %141 = icmp eq i8 %140, -1
  %142 = inttoptr i64 %138 to ptr
  %143 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %49, i32 0, i32 2
  %144 = select i1 %141, ptr %142, ptr %143
  %145 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %49, i32 0, i32 4
  %146 = load i64, ptr %145, align 8
  %147 = zext i8 %140 to i64
  %148 = select i1 %141, i64 %146, i64 %147
  %149 = insertvalue { ptr, i64 } poison, ptr %144, 0
  %150 = insertvalue { ptr, i64 } %149, i64 %148, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %49, i64 24, i1 false)
  %151 = extractvalue { ptr, i64 } %150, 0
  %152 = extractvalue { ptr, i64 } %150, 1
  %153 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %154 = load ptr, ptr %153, align 8
  %155 = icmp eq ptr %154, null
  br i1 %155, label %156, label %159, !prof !0

156:
  %157 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %158 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %157, i64 %158)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 13)
  ret i32 1

159:
  %160 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %161 = load ptr, ptr %160, align 8
  %162 = call i32 %154(ptr %161, ptr %151, i64 %152)
  %163 = icmp eq i32 %162, -1
  br i1 %163, label %164, label %165, !prof !0

164:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

165:
  %166 = icmp ne i32 %162, 0
  %167 = icmp ne i32 %162, 1
  %168 = and i1 %166, %167
  br i1 %168, label %169, label %172, !prof !0

169:
  %170 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %171 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %170, i64 %171)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 13)
  ret i32 1

172:
  %173 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %174 = load i64, ptr %173, align 8
  %175 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  %176 = load i8, ptr %175, align 1
  %177 = icmp eq i8 %176, -1
  %178 = inttoptr i64 %174 to ptr
  %179 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 2
  %180 = select i1 %177, ptr %178, ptr %179
  %181 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  %182 = load i64, ptr %181, align 8
  %183 = zext i8 %176 to i64
  %184 = select i1 %177, i64 %182, i64 %183
  %185 = insertvalue { ptr, i64 } poison, ptr %180, 0
  %186 = insertvalue { ptr, i64 } %185, i64 %184, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %9, ptr %50)
  %187 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 3
  %188 = load i64, ptr %187, align 8
  %189 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 1
  %190 = load i8, ptr %189, align 1
  %191 = icmp eq i8 %190, -1
  %192 = inttoptr i64 %188 to ptr
  %193 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 2
  %194 = select i1 %191, ptr %192, ptr %193
  %195 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 4
  %196 = load i64, ptr %195, align 8
  %197 = zext i8 %190 to i64
  %198 = select i1 %191, i64 %196, i64 %197
  %199 = insertvalue { ptr, i64 } poison, ptr %194, 0
  %200 = insertvalue { ptr, i64 } %199, i64 %198, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %50, i64 24, i1 false)
  %201 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  %202 = load i64, ptr %201, align 8
  %203 = inttoptr i64 %202 to ptr
  %204 = ptrtoint ptr %203 to i64
  %205 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %51, i32 0, i32 3
  store i64 %204, ptr %205, align 8
  %206 = call i32 @luce_rt_release(ptr %1, ptr %51)
  %207 = icmp ne i32 %206, 0
  br i1 %207, label %208, label %209, !prof !0

208:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 18)
  ret i32 1

209:
  %210 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  %211 = load i64, ptr %210, align 8
  %212 = inttoptr i64 %211 to ptr
  call void @luce_rt_drop_storage(ptr %1, ptr %8, ptr %54)
  %213 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %54, i32 0, i32 3
  %214 = load i64, ptr %213, align 8
  %215 = inttoptr i64 %214 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %54, i64 24, i1 false)
  %216 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %217 = load i64, ptr %216, align 8
  %218 = inttoptr i64 %217 to ptr
  call void @luce_rt_drop_storage(ptr %1, ptr %7, ptr %55)
  %219 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %55, i32 0, i32 3
  %220 = load i64, ptr %219, align 8
  %221 = inttoptr i64 %220 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %7, ptr align 8 %55, i64 24, i1 false)
  ret i32 0
}

define internal i32 @luce.2.Width.measure(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, ptr align 8 readonly nonnull noundef %3, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %4) {
5:
  %6 = alloca ptr, align 8
  store ptr %3, ptr %6, align 8
  br label %7

7:
  %8 = load ptr, ptr %6, align 8
  %9 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i64 0
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %11 = load i64, ptr %10, align 8
  store i64 %11, ptr %4, align 8
  ret i32 0
}

define internal i32 @luce.bound.2(ptr %0, ptr %1, i64 %2, ptr %3, ptr %4) {
5:
  %6 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %3, i32 0, i32 3
  %7 = load i64, ptr %6, align 8
  %8 = inttoptr i64 %7 to ptr
  %9 = call i32 @luce.2.Width.measure(ptr %0, ptr %1, i64 %2, ptr %8, ptr %4)
  ret i32 %9
}

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #0

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %0, i64 %1) #1

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_struct_make(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull noundef %1, i64 %2, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %3) #2

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #3

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_own_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #2

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #4

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #5

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #2

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #6

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
  %13 = call ptr @luce_rt_open(ptr @luce.functions, i64 3)
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
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.1, i64 19)
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
declare noalias ptr @luce_rt_open(ptr readonly %0, i64 %1) #7

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_files_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9, ptr %10, ptr %11) #8

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #9

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #8

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #6

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #10

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #10

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #11

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #11

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #6

attributes #0 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #1 = { nounwind speculatable willreturn nofree nosync nocallback memory(none) }
attributes #2 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #3 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #4 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #5 = { nounwind cold willreturn memory(argmem: write) }
attributes #6 = { nounwind memory(readwrite) }
attributes #7 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #8 = { nounwind willreturn memory(argmem: readwrite) }
attributes #9 = { nounwind willreturn memory(readwrite) }
attributes #10 = { cold }
attributes #11 = { nounwind willreturn memory(argmem: read) }

!0 = !{!"branch_weights", i32 1, i32 2000}
!1 = !{!3}
!2 = !{!4}
!3 = !{!"luce.rows", !5}
!4 = !{!"luce.elements", !5}
!5 = !{!"luce.alias"}
