; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/classes.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/classes.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.1 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.2 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.3 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce.text.4 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.5 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.6 = private unnamed_addr constant [4 x i8] c"main"
@luce.text.7 = private unnamed_addr constant [58 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/classes.luc"
@luce.origins.0 = private constant [20 x { i32, i32 }] [{ i32, i32 } { i32 12, i32 5 }, { i32, i32 } { i32 12, i32 5 }, { i32, i32 } { i32 12, i32 5 }, { i32, i32 } { i32 12, i32 5 }, { i32, i32 } { i32 13, i32 5 }, { i32, i32 } { i32 13, i32 5 }, { i32, i32 } { i32 13, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }, { i32, i32 } { i32 14, i32 5 }]
@luce.text.8 = private unnamed_addr constant [12 x i8] c"Counter.next"
@luce.origins.1 = private constant [8 x { i32, i32 }] [{ i32, i32 } { i32 8, i32 9 }, { i32, i32 } { i32 8, i32 9 }, { i32, i32 } { i32 8, i32 9 }, { i32, i32 } { i32 8, i32 9 }, { i32, i32 } { i32 8, i32 9 }, { i32, i32 } { i32 9, i32 9 }, { i32, i32 } { i32 9, i32 9 }, { i32, i32 } { i32 9, i32 9 }]
@luce.text.9 = private unnamed_addr constant [12 x i8] c"Counter.init"
@luce.origins.2 = private constant [7 x { i32, i32 }] [{ i32, i32 } { i32 5, i32 1 }, { i32, i32 } { i32 5, i32 1 }, { i32, i32 } { i32 5, i32 9 }, { i32, i32 } { i32 5, i32 9 }, { i32, i32 } { i32 5, i32 1 }, { i32, i32 } { i32 5, i32 1 }, { i32, i32 } { i32 5, i32 1 }]
@luce.functions = private constant [3 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.6, i64 4, ptr @luce.text.7, i64 58, ptr @luce.origins.0, i64 20 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.8, i64 12, ptr @luce.text.7, i64 58, ptr @luce.origins.1, i64 8 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.9, i64 12, ptr @luce.text.7, i64 58, ptr @luce.origins.2, i64 7 }]
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  %9 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  store i64 4294967295, ptr %6, align 8
  store i64 4294967295, ptr %7, align 8
  store i64 4294967295, ptr %8, align 8
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 0
  store i8 4, ptr %10, align 1
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  store i8 -1, ptr %11, align 1
  %12 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %13 = ptrtoint ptr %12 to i64
  %14 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  store i64 %13, ptr %14, align 8
  %15 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  store i64 %15, ptr %16, align 8
  %17 = sub nsw i64 %2, 1
  %18 = alloca i64, align 8
  %19 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %20 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 0
  store i8 6, ptr %20, align 1
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 4
  store i64 0, ptr %21, align 8
  %22 = alloca i64, align 8
  %23 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %24 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 0
  store i8 2, ptr %24, align 1
  %25 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 4
  store i64 0, ptr %25, align 8
  %26 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %27 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %28 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %29 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 0
  store i8 6, ptr %29, align 1
  %30 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 4
  store i64 0, ptr %30, align 8
  %31 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %32 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 0
  store i8 6, ptr %32, align 1
  %33 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 4
  store i64 0, ptr %33, align 8
  br label %34

34:
  %35 = load i64, ptr %5, align 8
  %36 = trunc i64 %35 to i32
  %37 = lshr i64 %35, 32
  %38 = trunc i64 %37 to i32
  %39 = icmp eq i32 %36, -1
  br i1 %39, label %40, label %43, !prof !0

40:
  %41 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %42 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %41, i64 %42)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

43:
  %44 = getelementptr inbounds i8, ptr %1, i64 96
  %45 = load ptr, ptr %44, align 8!alias.scope !1, !noalias !2
  %46 = zext i32 %36 to i64
  %47 = mul nsw i64 %46, 112
  %48 = getelementptr inbounds i8, ptr %45, i64 %47
  %49 = getelementptr inbounds i8, ptr %48, i64 96
  %50 = load i32, ptr %49, align 4, !alias.scope !1, !noalias !2
  %51 = icmp ne i32 %50, %38
  br i1 %51, label %52, label %55, !prof !0

52:
  %53 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %54 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %53, i64 %54)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

55:
  %56 = and i32 %50, 1
  %57 = icmp ne i32 %56, 0
  br i1 %57, label %58, label %61, !prof !0

58:
  %59 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %60 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %59, i64 %60)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

61:
  %62 = getelementptr inbounds i8, ptr %48, i64 16
  %63 = load i64, ptr %62, align 8!alias.scope !1, !noalias !2
  %64 = load ptr, ptr %48, align 8, !alias.scope !1, !noalias !2
  %65 = icmp slt i64 %17, 1
  br i1 %65, label %66, label %69, !prof !0

66:
  %67 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 0
  %68 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %67, i64 %68)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

69:
  %70 = call i32 @luce.2.Counter.init(ptr %0, ptr %1, i64 %17, i64 %63, ptr %18)
  %71 = icmp ne i32 %70, 0
  br i1 %71, label %72, label %73, !prof !0

72:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

73:
  %74 = load i64, ptr %18, align 8
  store i64 %74, ptr %7, align 8
  %75 = load i64, ptr %7, align 8
  %76 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %19, i32 0, i32 3
  store i64 %75, ptr %76, align 8
  %77 = call i32 @luce_rt_retain(ptr %1, ptr %19)
  %78 = icmp ne i32 %77, 0
  br i1 %78, label %79, label %80, !prof !0

79:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 5)
  ret i32 1

80:
  store i64 %75, ptr %8, align 8
  %81 = load i64, ptr %8, align 8
  %82 = icmp slt i64 %17, 1
  br i1 %82, label %83, label %86, !prof !0

83:
  %84 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 0
  %85 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %84, i64 %85)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 8)
  ret i32 1

86:
  %87 = call i32 @luce.1.Counter.next(ptr %0, ptr %1, i64 %17, i64 %81, ptr %22)
  %88 = icmp ne i32 %87, 0
  br i1 %88, label %89, label %90, !prof !0

89:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 8)
  ret i32 1

90:
  %91 = load i64, ptr %22, align 8
  %92 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 3
  store i64 %91, ptr %92, align 8
  %93 = call i32 @luce_rt_str(ptr %1, ptr %23, ptr %26)
  %94 = icmp ne i32 %93, 0
  br i1 %94, label %95, label %96, !prof !0

95:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 9)
  ret i32 1

96:
  %97 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %26, i32 0, i32 3
  %98 = load i64, ptr %97, align 8
  %99 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %26, i32 0, i32 1
  %100 = load i8, ptr %99, align 1
  %101 = icmp eq i8 %100, -1
  %102 = inttoptr i64 %98 to ptr
  %103 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %26, i32 0, i32 2
  %104 = select i1 %101, ptr %102, ptr %103
  %105 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %26, i32 0, i32 4
  %106 = load i64, ptr %105, align 8
  %107 = zext i8 %100 to i64
  %108 = select i1 %101, i64 %106, i64 %107
  %109 = insertvalue { ptr, i64 } poison, ptr %104, 0
  %110 = insertvalue { ptr, i64 } %109, i64 %108, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %26, i64 24, i1 false)
  %111 = extractvalue { ptr, i64 } %110, 0
  %112 = extractvalue { ptr, i64 } %110, 1
  %113 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %114 = load ptr, ptr %113, align 8
  %115 = icmp eq ptr %114, null
  br i1 %115, label %116, label %119, !prof !0

116:
  %117 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %118 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %117, i64 %118)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 11)
  ret i32 1

119:
  %120 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %121 = load ptr, ptr %120, align 8
  %122 = call i32 %114(ptr %121, ptr %111, i64 %112)
  %123 = icmp eq i32 %122, -1
  br i1 %123, label %124, label %125, !prof !0

124:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

125:
  %126 = icmp ne i32 %122, 0
  %127 = icmp ne i32 %122, 1
  %128 = and i1 %126, %127
  br i1 %128, label %129, label %132, !prof !0

129:
  %130 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %131 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %130, i64 %131)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 11)
  ret i32 1

132:
  %133 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %134 = load i64, ptr %133, align 8
  %135 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  %136 = load i8, ptr %135, align 1
  %137 = icmp eq i8 %136, -1
  %138 = inttoptr i64 %134 to ptr
  %139 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 2
  %140 = select i1 %137, ptr %138, ptr %139
  %141 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  %142 = load i64, ptr %141, align 8
  %143 = zext i8 %136 to i64
  %144 = select i1 %137, i64 %142, i64 %143
  %145 = insertvalue { ptr, i64 } poison, ptr %140, 0
  %146 = insertvalue { ptr, i64 } %145, i64 %144, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %9, ptr %27)
  %147 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 3
  %148 = load i64, ptr %147, align 8
  %149 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 1
  %150 = load i8, ptr %149, align 1
  %151 = icmp eq i8 %150, -1
  %152 = inttoptr i64 %148 to ptr
  %153 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 2
  %154 = select i1 %151, ptr %152, ptr %153
  %155 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 4
  %156 = load i64, ptr %155, align 8
  %157 = zext i8 %150 to i64
  %158 = select i1 %151, i64 %156, i64 %157
  %159 = insertvalue { ptr, i64 } poison, ptr %154, 0
  %160 = insertvalue { ptr, i64 } %159, i64 %158, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %27, i64 24, i1 false)
  %161 = load i64, ptr %8, align 8
  %162 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 3
  store i64 %161, ptr %162, align 8
  %163 = call i32 @luce_rt_release(ptr %1, ptr %28)
  %164 = icmp ne i32 %163, 0
  br i1 %164, label %165, label %166, !prof !0

165:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 16)
  ret i32 1

166:
  %167 = load i64, ptr %7, align 8
  %168 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 3
  store i64 %167, ptr %168, align 8
  %169 = call i32 @luce_rt_release(ptr %1, ptr %31)
  %170 = icmp ne i32 %169, 0
  br i1 %170, label %171, label %172, !prof !0

171:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 18)
  ret i32 1

172:
  ret i32 0
}

define internal i32 @luce.1.Counter.next(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %4) {
5:
  %6 = alloca i64, align 8
  store i64 %3, ptr %6, align 8
  %7 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %8 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 0
  store i8 6, ptr %8, align 1
  %9 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  store i64 0, ptr %9, align 8
  %10 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %11 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %11, i32 0, i32 0
  store i8 6, ptr %12, align 1
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %11, i32 0, i32 4
  store i64 0, ptr %13, align 8
  %14 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %15 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 0
  store i8 2, ptr %15, align 1
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 4
  store i64 0, ptr %16, align 8
  %17 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 0
  store i8 6, ptr %18, align 1
  %19 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 4
  store i64 0, ptr %19, align 8
  %20 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %21

21:
  %22 = load i64, ptr %6, align 8
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  store i64 %22, ptr %23, align 8
  %24 = call i32 @luce_rt_class_get(ptr %1, ptr %7, i64 0, i64 0, ptr %10)
  %25 = icmp ne i32 %24, 0
  br i1 %25, label %26, label %27, !prof !0

26:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 2)
  ret i32 1

27:
  %28 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 3
  %29 = load i64, ptr %28, align 8
  %30 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %29, i64 1)
  %31 = extractvalue { i64, i1 } %30, 0
  %32 = extractvalue { i64, i1 } %30, 1
  br i1 %32, label %33, label %36, !prof !0

33:
  %34 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 16 }, 0
  %35 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %34, i64 %35)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 3)
  ret i32 1

36:
  %37 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %11, i32 0, i32 3
  store i64 %22, ptr %37, align 8
  %38 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 3
  store i64 %31, ptr %38, align 8
  %39 = call i32 @luce_rt_class_set(ptr %1, ptr %11, i64 0, i64 0, ptr %14)
  %40 = icmp ne i32 %39, 0
  br i1 %40, label %41, label %42, !prof !0

41:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 4)
  ret i32 1

42:
  %43 = load i64, ptr %6, align 8
  %44 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 3
  store i64 %43, ptr %44, align 8
  %45 = call i32 @luce_rt_class_get(ptr %1, ptr %17, i64 0, i64 0, ptr %20)
  %46 = icmp ne i32 %45, 0
  br i1 %46, label %47, label %48, !prof !0

47:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 6)
  ret i32 1

48:
  %49 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 3
  %50 = load i64, ptr %49, align 8
  store i64 %50, ptr %4, align 8
  ret i32 0
}

define internal i32 @luce.2.Counter.init(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %4) {
5:
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  store i64 %3, ptr %6, align 8
  store i64 0, ptr %7, align 8
  %8 = alloca { i8, i8, [6 x i8], i64, i64 },i64 1, align 8
  %9 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i64 0
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 0
  store i8 2, ptr %10, align 1
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  store i64 0, ptr %11, align 8
  %12 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %13

13:
  store i64 0, ptr %7, align 8
  %14 = load i64, ptr %6, align 8
  store i64 %14, ptr %7, align 8
  %15 = load i64, ptr %7, align 8
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  store i64 %15, ptr %16, align 8
  %17 = call i32 @luce_rt_class_make(ptr %1, i64 0, i64 -1, ptr %8, i64 1, ptr %12)
  %18 = icmp ne i32 %17, 0
  br i1 %18, label %19, label %20, !prof !0

19:
  call void @luce_rt_unwound(ptr %1, i32 2, i32 5)
  ret i32 1

20:
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %12, i32 0, i32 3
  %22 = load i64, ptr %21, align 8
  store i64 %22, ptr %4, align 8
  ret i32 0
}

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #0

; Function Attrs: nounwind willreturn memory(readwrite)
declare i32 @luce_rt_retain(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #1

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #2

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #3

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #4

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #5

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #6

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite)
declare i32 @luce_rt_class_get(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, i64 %2, i64 %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #7

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %0, i64 %1) #8

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_class_set(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, i64 %2, i64 %3, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %4) #6

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_class_make(ptr nocapture nonnull noundef %0, i64 %1, i64 %2, ptr align 8 nocapture readonly nonnull noundef %3, i64 %4, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %5) #6

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
declare noalias ptr @luce_rt_open(ptr readonly %0, i64 %1) #9

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_files_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9, ptr %10, ptr %11) #10

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #1

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #10

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #6

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #11

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #11

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #12

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #12

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #6

attributes #0 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #1 = { nounwind willreturn memory(readwrite) }
attributes #2 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #3 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #4 = { nounwind cold willreturn memory(argmem: write) }
attributes #5 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #6 = { nounwind memory(readwrite) }
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
