; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/closures.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/closures.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.1 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.2 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.3 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce.function_table = private constant [3 x ptr] [ptr null, ptr null, ptr @luce.bound.2]
@luce.text.4 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.5 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.6 = private unnamed_addr constant [10 x i8] c"make_adder"
@luce.text.7 = private unnamed_addr constant [59 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/closures.luc"
@luce.origins.0 = private constant [13 x { i32, i32 }] [{ i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }]
@luce.text.8 = private unnamed_addr constant [4 x i8] c"main"
@luce.origins.1 = private constant [19 x { i32, i32 }] [{ i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 7, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }, { i32, i32 } { i32 8, i32 5 }]
@luce.text.9 = private unnamed_addr constant [25 x i8] c"make_adder.(closure@2.33)"
@luce.origins.2 = private constant [7 x { i32, i32 }] [{ i32, i32 } { i32 3, i32 16 }, { i32, i32 } { i32 3, i32 16 }, { i32, i32 } { i32 3, i32 16 }, { i32, i32 } { i32 3, i32 9 }, { i32, i32 } { i32 3, i32 9 }, { i32, i32 } { i32 3, i32 9 }, { i32, i32 } { i32 3, i32 9 }]
@luce.functions = private constant [3 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.6, i64 10, ptr @luce.text.7, i64 59, ptr @luce.origins.0, i64 13 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.8, i64 4, ptr @luce.text.7, i64 59, ptr @luce.origins.1, i64 19 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.9, i64 25, ptr @luce.text.7, i64 59, ptr @luce.origins.2, i64 7 }]
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.make_adder(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %4) {
5:
  %6 = alloca i64, align 8
  %7 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %8 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %6, align 8
  %9 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 0
  store i8 12, ptr %9, align 1
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  store i64 2, ptr %10, align 8
  %11 = ptrtoint ptr null to i64
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  store i64 %11, ptr %12, align 8
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 0
  store i8 12, ptr %13, align 1
  %14 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  store i64 2, ptr %14, align 8
  %15 = ptrtoint ptr null to i64
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  store i64 %15, ptr %16, align 8
  %17 = alloca { i8, i8, [6 x i8], i64, i64 },i64 1, align 8
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i64 0
  %19 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %18, i32 0, i32 0
  store i8 2, ptr %19, align 1
  %20 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %18, i32 0, i32 4
  store i64 0, ptr %20, align 8
  %21 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %22 = alloca { i8, i8, [6 x i8], i64, i64 },i64 2, align 8
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i64 0
  %24 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 0
  store i8 7, ptr %24, align 1
  %25 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 4
  store i64 0, ptr %25, align 8
  %26 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i64 1
  %27 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %28 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %29 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 0
  store i8 12, ptr %29, align 1
  %30 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 4
  store i64 2, ptr %30, align 8
  %31 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %32 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 0
  store i8 12, ptr %32, align 1
  %33 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 4
  store i64 2, ptr %33, align 8
  %34 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %35 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %36 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 0
  store i8 12, ptr %36, align 1
  %37 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 4
  store i64 2, ptr %37, align 8
  %38 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %39

39:
  %40 = load i64, ptr %6, align 8
  %41 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %18, i32 0, i32 3
  store i64 %40, ptr %41, align 8
  %42 = call i32 @luce_rt_class_make(ptr %1, i64 0, i64 -1, ptr %17, i64 1, ptr %21)
  %43 = icmp ne i32 %42, 0
  br i1 %43, label %44, label %45, !prof !0

44:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

45:
  %46 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %21, i32 0, i32 3
  %47 = load i64, ptr %46, align 8
  %48 = zext i32 2 to i64
  %49 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 3
  store i64 %48, ptr %49, align 8
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %26, ptr align 8 %21, i64 24, i1 false)
  %50 = call i32 @luce_rt_function_make(ptr %1, ptr %22, i64 2, ptr %27)
  %51 = icmp ne i32 %50, 0
  br i1 %51, label %52, label %53, !prof !0

52:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

53:
  %54 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 3
  %55 = load i64, ptr %54, align 8
  %56 = inttoptr i64 %55 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %27, i64 24, i1 false)
  %57 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  %58 = load i64, ptr %57, align 8
  %59 = inttoptr i64 %58 to ptr
  %60 = ptrtoint ptr %59 to i64
  %61 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 3
  store i64 %60, ptr %61, align 8
  %62 = call i32 @luce_rt_retain(ptr %1, ptr %28)
  %63 = icmp ne i32 %62, 0
  br i1 %63, label %64, label %65, !prof !0

64:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 5)
  ret i32 1

65:
  %66 = ptrtoint ptr %59 to i64
  %67 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 3
  store i64 %66, ptr %67, align 8
  %68 = call i32 @luce_rt_own_storage(ptr %1, ptr %31, ptr %34)
  %69 = icmp ne i32 %68, 0
  br i1 %69, label %70, label %71, !prof !0

70:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 6)
  ret i32 1

71:
  %72 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %34, i32 0, i32 3
  %73 = load i64, ptr %72, align 8
  %74 = inttoptr i64 %73 to ptr
  %75 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  %76 = load i64, ptr %75, align 8
  %77 = inttoptr i64 %76 to ptr
  %78 = ptrtoint ptr %77 to i64
  %79 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 3
  store i64 %78, ptr %79, align 8
  %80 = call i32 @luce_rt_release(ptr %1, ptr %35)
  %81 = icmp ne i32 %80, 0
  br i1 %81, label %82, label %83, !prof !0

82:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 8)
  ret i32 1

83:
  %84 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  %85 = load i64, ptr %84, align 8
  %86 = inttoptr i64 %85 to ptr
  call void @luce_rt_drop_storage(ptr %1, ptr %8, ptr %38)
  %87 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 3
  %88 = load i64, ptr %87, align 8
  %89 = inttoptr i64 %88 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %38, i64 24, i1 false)
  store ptr %74, ptr %4, align 8
  ret i32 0
}

define internal i32 @luce.1.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %7 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %8 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  %9 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 0
  store i8 12, ptr %9, align 1
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 4
  store i64 2, ptr %10, align 8
  %11 = ptrtoint ptr null to i64
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 3
  store i64 %11, ptr %12, align 8
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 0
  store i8 12, ptr %13, align 1
  %14 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  store i64 2, ptr %14, align 8
  %15 = ptrtoint ptr null to i64
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  store i64 %15, ptr %16, align 8
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 0
  store i8 4, ptr %17, align 1
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 1
  store i8 -1, ptr %18, align 1
  %19 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %20 = ptrtoint ptr %19 to i64
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  store i64 %20, ptr %21, align 8
  %22 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  store i64 %22, ptr %23, align 8
  %24 = sub nsw i64 %2, 1
  %25 = alloca ptr, align 8
  %26 = alloca i64, align 8
  %27 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %28 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 0
  store i8 2, ptr %28, align 1
  %29 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 4
  store i64 0, ptr %29, align 8
  %30 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %31 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %32 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %33 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 0
  store i8 12, ptr %33, align 1
  %34 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 4
  store i64 2, ptr %34, align 8
  %35 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %36

36:
  %37 = load i64, ptr %5, align 8
  %38 = trunc i64 %37 to i32
  %39 = lshr i64 %37, 32
  %40 = trunc i64 %39 to i32
  %41 = icmp eq i32 %38, -1
  br i1 %41, label %42, label %45, !prof !0

42:
  %43 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %44 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %43, i64 %44)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

45:
  %46 = getelementptr inbounds i8, ptr %1, i64 96
  %47 = load ptr, ptr %46, align 8!alias.scope !1, !noalias !2
  %48 = zext i32 %38 to i64
  %49 = mul nsw i64 %48, 112
  %50 = getelementptr inbounds i8, ptr %47, i64 %49
  %51 = getelementptr inbounds i8, ptr %50, i64 96
  %52 = load i32, ptr %51, align 4, !alias.scope !1, !noalias !2
  %53 = icmp ne i32 %52, %40
  br i1 %53, label %54, label %57, !prof !0

54:
  %55 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %56 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %55, i64 %56)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

57:
  %58 = and i32 %52, 1
  %59 = icmp ne i32 %58, 0
  br i1 %59, label %60, label %63, !prof !0

60:
  %61 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %62 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %61, i64 %62)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

63:
  %64 = getelementptr inbounds i8, ptr %50, i64 16
  %65 = load i64, ptr %64, align 8!alias.scope !1, !noalias !2
  %66 = load ptr, ptr %50, align 8, !alias.scope !1, !noalias !2
  %67 = icmp slt i64 %24, 1
  br i1 %67, label %68, label %71, !prof !0

68:
  %69 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 0
  %70 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %69, i64 %70)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 2)
  ret i32 1

71:
  %72 = call i32 @luce.0.make_adder(ptr %0, ptr %1, i64 %24, i64 %65, ptr %25)
  %73 = icmp ne i32 %72, 0
  br i1 %73, label %74, label %75, !prof !0

74:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 2)
  ret i32 1

75:
  %76 = load ptr, ptr %25, align 8
  %77 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 0
  store i8 12, ptr %77, align 1
  %78 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  store i64 2, ptr %78, align 8
  %79 = ptrtoint ptr %76 to i64
  %80 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  store i64 %79, ptr %80, align 8
  %81 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %82 = load i64, ptr %81, align 8
  %83 = inttoptr i64 %82 to ptr
  %84 = icmp slt i64 %24, 1
  br i1 %84, label %85, label %88, !prof !0

85:
  %86 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 0
  %87 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %86, i64 %87)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 6)
  ret i32 1

88:
  %89 = ptrtoint ptr %83 to i64
  %90 = icmp eq i64 %89, 0
  br i1 %90, label %91, label %94, !prof !0

91:
  %92 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %93 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %92, i64 %93)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 6)
  ret i32 1

94:
  %95 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %83, i64 0
  %96 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %95, i32 0, i32 3
  %97 = load i64, ptr %96, align 8
  %98 = trunc i64 %97 to i32
  %99 = icmp uge i32 %98, 3
  br i1 %99, label %100, label %103, !prof !0

100:
  %101 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %102 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %101, i64 %102)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 6)
  ret i32 1

103:
  %104 = zext i32 %98 to i64
  %105 = getelementptr inbounds ptr, ptr @luce.function_table, i64 %104
  %106 = load ptr, ptr %105, align 8
  %107 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %83, i64 1
  %108 = call i32 %106(ptr %0, ptr %1, i64 %24, ptr %107, i64 2, ptr %26)
  %109 = icmp ne i32 %108, 0
  br i1 %109, label %110, label %111, !prof !0

110:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 6)
  ret i32 1

111:
  %112 = load i64, ptr %26, align 8
  %113 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 3
  store i64 %112, ptr %113, align 8
  %114 = call i32 @luce_rt_str(ptr %1, ptr %27, ptr %30)
  %115 = icmp ne i32 %114, 0
  br i1 %115, label %116, label %117, !prof !0

116:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 7)
  ret i32 1

117:
  %118 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 3
  %119 = load i64, ptr %118, align 8
  %120 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 1
  %121 = load i8, ptr %120, align 1
  %122 = icmp eq i8 %121, -1
  %123 = inttoptr i64 %119 to ptr
  %124 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 2
  %125 = select i1 %122, ptr %123, ptr %124
  %126 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 4
  %127 = load i64, ptr %126, align 8
  %128 = zext i8 %121 to i64
  %129 = select i1 %122, i64 %127, i64 %128
  %130 = insertvalue { ptr, i64 } poison, ptr %125, 0
  %131 = insertvalue { ptr, i64 } %130, i64 %129, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %30, i64 24, i1 false)
  %132 = extractvalue { ptr, i64 } %131, 0
  %133 = extractvalue { ptr, i64 } %131, 1
  %134 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %135 = load ptr, ptr %134, align 8
  %136 = icmp eq ptr %135, null
  br i1 %136, label %137, label %140, !prof !0

137:
  %138 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %139 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %138, i64 %139)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 9)
  ret i32 1

140:
  %141 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %142 = load ptr, ptr %141, align 8
  %143 = call i32 %135(ptr %142, ptr %132, i64 %133)
  %144 = icmp eq i32 %143, -1
  br i1 %144, label %145, label %146, !prof !0

145:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

146:
  %147 = icmp ne i32 %143, 0
  %148 = icmp ne i32 %143, 1
  %149 = and i1 %147, %148
  br i1 %149, label %150, label %153, !prof !0

150:
  %151 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %152 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %151, i64 %152)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 9)
  ret i32 1

153:
  %154 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  %155 = load i64, ptr %154, align 8
  %156 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 1
  %157 = load i8, ptr %156, align 1
  %158 = icmp eq i8 %157, -1
  %159 = inttoptr i64 %155 to ptr
  %160 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 2
  %161 = select i1 %158, ptr %159, ptr %160
  %162 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  %163 = load i64, ptr %162, align 8
  %164 = zext i8 %157 to i64
  %165 = select i1 %158, i64 %163, i64 %164
  %166 = insertvalue { ptr, i64 } poison, ptr %161, 0
  %167 = insertvalue { ptr, i64 } %166, i64 %165, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %8, ptr %31)
  %168 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 3
  %169 = load i64, ptr %168, align 8
  %170 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 1
  %171 = load i8, ptr %170, align 1
  %172 = icmp eq i8 %171, -1
  %173 = inttoptr i64 %169 to ptr
  %174 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 2
  %175 = select i1 %172, ptr %173, ptr %174
  %176 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 4
  %177 = load i64, ptr %176, align 8
  %178 = zext i8 %171 to i64
  %179 = select i1 %172, i64 %177, i64 %178
  %180 = insertvalue { ptr, i64 } poison, ptr %175, 0
  %181 = insertvalue { ptr, i64 } %180, i64 %179, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %31, i64 24, i1 false)
  %182 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %183 = load i64, ptr %182, align 8
  %184 = inttoptr i64 %183 to ptr
  %185 = ptrtoint ptr %184 to i64
  %186 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 3
  store i64 %185, ptr %186, align 8
  %187 = call i32 @luce_rt_release(ptr %1, ptr %32)
  %188 = icmp ne i32 %187, 0
  br i1 %188, label %189, label %190, !prof !0

189:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 14)
  ret i32 1

190:
  %191 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %192 = load i64, ptr %191, align 8
  %193 = inttoptr i64 %192 to ptr
  call void @luce_rt_drop_storage(ptr %1, ptr %7, ptr %35)
  %194 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 3
  %195 = load i64, ptr %194, align 8
  %196 = inttoptr i64 %195 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %7, ptr align 8 %35, i64 24, i1 false)
  ret i32 0
}

define internal i32 @"luce.2.make_adder.(closure@2.33)"(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3, i64 %4, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %5) {
6:
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  %9 = alloca i64, align 8
  store i64 %3, ptr %7, align 8
  store i64 %4, ptr %8, align 8
  store i64 0, ptr %9, align 8
  %10 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 0
  store i8 6, ptr %11, align 1
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 4
  store i64 0, ptr %12, align 8
  %13 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %14

14:
  %15 = load i64, ptr %7, align 8
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 3
  store i64 %15, ptr %16, align 8
  %17 = call i32 @luce_rt_class_get(ptr %1, ptr %10, i64 0, i64 0, ptr %13)
  %18 = icmp ne i32 %17, 0
  br i1 %18, label %19, label %20, !prof !0

19:
  call void @luce_rt_unwound(ptr %1, i32 2, i32 1)
  ret i32 1

20:
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %13, i32 0, i32 3
  %22 = load i64, ptr %21, align 8
  store i64 %22, ptr %9, align 8
  %23 = load i64, ptr %9, align 8
  %24 = load i64, ptr %8, align 8
  %25 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %23, i64 %24)
  %26 = extractvalue { i64, i1 } %25, 0
  %27 = extractvalue { i64, i1 } %25, 1
  br i1 %27, label %28, label %31, !prof !0

28:
  %29 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 16 }, 0
  %30 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %29, i64 %30)
  call void @luce_rt_unwound(ptr %1, i32 2, i32 5)
  ret i32 1

31:
  store i64 %26, ptr %5, align 8
  ret i32 0
}

define internal i32 @luce.bound.2(ptr %0, ptr %1, i64 %2, ptr %3, i64 %4, ptr %5) {
6:
  %7 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %3, i32 0, i32 3
  %8 = load i64, ptr %7, align 8
  %9 = call i32 @"luce.2.make_adder.(closure@2.33)"(ptr %0, ptr %1, i64 %2, i64 %8, i64 %4, ptr %5)
  ret i32 %9
}

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_class_make(ptr nocapture nonnull noundef %0, i64 %1, i64 %2, ptr align 8 nocapture readonly nonnull noundef %3, i64 %4, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %5) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #1

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #2

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_function_make(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull noundef %1, i64 %2, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %3) #3

; Function Attrs: nounwind willreturn memory(readwrite)
declare i32 @luce_rt_retain(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #4

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_own_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #0

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #1

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #5

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #6

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite)
declare i32 @luce_rt_class_get(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, i64 %2, i64 %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #7

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %0, i64 %1) #8

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
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.3, i64 19)
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
declare noalias ptr @luce_rt_open(ptr readonly %0, i64 %1) #9

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_files_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9, ptr %10, ptr %11) #10

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #4

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #10

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #0

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #11

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #11

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #12

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #12

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #0

attributes #0 = { nounwind memory(readwrite) }
attributes #1 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #2 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #3 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #4 = { nounwind willreturn memory(readwrite) }
attributes #5 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #6 = { nounwind cold willreturn memory(argmem: write) }
attributes #7 = { nounwind willreturn memory(read, argmem: readwrite) }
attributes #8 = { nounwind speculatable willreturn nofree nosync nocallback memory(none) }
attributes #9 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #10 = { nounwind willreturn memory(argmem: readwrite) }
attributes #11 = { cold }
attributes #12 = { nounwind willreturn memory(argmem: read) }

!0 = !{!"branch_weights", i32 1, i32 2000}
!1 = !{!3}
!2 = !{!4}
!3 = !{!"luce.rows", !5}
!4 = !{!"luce.elements", !5}
!5 = !{!"luce.alias"}
