; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/standard.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/standard.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.1 = private unnamed_addr constant [4 x i8] c"luce"
@luce.text.2 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.3 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.4 = private unnamed_addr constant [1 x i8] c"-"
@luce.text.5 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce.text.6 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.7 = private unnamed_addr constant [19 x i8] c"index out of bounds"
@luce.text.8 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.9 = private unnamed_addr constant [4 x i8] c"main"
@luce.text.10 = private unnamed_addr constant [59 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/standard.luc"
@luce.origins.0 = private constant [20 x { i32, i32 }] [{ i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }]
@luce.text.11 = private unnamed_addr constant [12 x i8] c"strings.join"
@luce.text.12 = private unnamed_addr constant [15 x i8] c"std/strings.luc"
@luce.origins.1 = private constant [48 x { i32, i32 }] [{ i32, i32 } { i32 182, i32 5 }, { i32, i32 } { i32 182, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 183, i32 5 }, { i32, i32 } { i32 184, i32 9 }, { i32, i32 } { i32 184, i32 9 }, { i32, i32 } { i32 184, i32 9 }, { i32, i32 } { i32 184, i32 9 }, { i32, i32 } { i32 185, i32 13 }, { i32, i32 } { i32 185, i32 13 }, { i32, i32 } { i32 185, i32 13 }, { i32, i32 } { i32 185, i32 13 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 186, i32 9 }, { i32, i32 } { i32 187, i32 5 }, { i32, i32 } { i32 187, i32 5 }, { i32, i32 } { i32 187, i32 5 }, { i32, i32 } { i32 187, i32 5 }, { i32, i32 } { i32 187, i32 5 }, { i32, i32 } { i32 187, i32 5 }]
@luce.functions = private constant [2 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.9, i64 4, ptr @luce.text.10, i64 59, ptr @luce.origins.0, i64 20 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.11, i64 12, ptr @luce.text.12, i64 15, ptr @luce.origins.1, i64 48 }]
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  %9 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 0
  store i8 4, ptr %10, align 1
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 1
  store i8 -1, ptr %11, align 1
  %12 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %13 = ptrtoint ptr %12 to i64
  %14 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 3
  store i64 %13, ptr %14, align 8
  %15 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 4
  store i64 %15, ptr %16, align 8
  store i64 4294967295, ptr %7, align 8
  store i64 4294967295, ptr %8, align 8
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 0
  store i8 4, ptr %17, align 1
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  store i8 -1, ptr %18, align 1
  %19 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %20 = ptrtoint ptr %19 to i64
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  store i64 %20, ptr %21, align 8
  %22 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  store i64 %22, ptr %23, align 8
  %24 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %25 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %24, i32 0, i32 0
  store i8 2, ptr %25, align 1
  %26 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %24, i32 0, i32 4
  store i64 0, ptr %26, align 8
  %27 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %28 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %29 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 0
  store i8 4, ptr %29, align 1
  %30 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 1
  store i8 -1, ptr %30, align 1
  %31 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %32 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %33 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 0
  store i8 4, ptr %33, align 1
  %34 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 1
  store i8 -1, ptr %34, align 1
  %35 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %36 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %37 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 0
  store i8 6, ptr %37, align 1
  %38 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 4
  store i64 0, ptr %38, align 8
  %39 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %40 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 0
  store i8 6, ptr %40, align 1
  %41 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 4
  store i64 0, ptr %41, align 8
  %42 = sub nsw i64 %2, 1
  %43 = alloca { ptr, i64 }, align 8
  %44 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %45 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %46 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 0
  store i8 6, ptr %46, align 1
  %47 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 4
  store i64 0, ptr %47, align 8
  br label %48

48:
  %49 = load i64, ptr %5, align 8
  %50 = trunc i64 %49 to i32
  %51 = lshr i64 %49, 32
  %52 = trunc i64 %51 to i32
  %53 = icmp eq i32 %50, -1
  br i1 %53, label %54, label %57, !prof !0

54:
  %55 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 0
  %56 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %55, i64 %56)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

57:
  %58 = getelementptr inbounds i8, ptr %1, i64 96
  %59 = load ptr, ptr %58, align 8!alias.scope !1, !noalias !2
  %60 = zext i32 %50 to i64
  %61 = mul nsw i64 %60, 112
  %62 = getelementptr inbounds i8, ptr %59, i64 %61
  %63 = getelementptr inbounds i8, ptr %62, i64 96
  %64 = load i32, ptr %63, align 4, !alias.scope !1, !noalias !2
  %65 = icmp ne i32 %64, %52
  br i1 %65, label %66, label %69, !prof !0

66:
  %67 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %68 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %67, i64 %68)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

69:
  %70 = and i32 %64, 1
  %71 = icmp ne i32 %70, 0
  br i1 %71, label %72, label %75, !prof !0

72:
  %73 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %74 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %73, i64 %74)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

75:
  %76 = getelementptr inbounds i8, ptr %62, i64 16
  %77 = load i64, ptr %76, align 8!alias.scope !1, !noalias !2
  %78 = load ptr, ptr %62, align 8, !alias.scope !1, !noalias !2
  %79 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %24, i32 0, i32 3
  store i64 %77, ptr %79, align 8
  %80 = call i32 @luce_rt_str(ptr %1, ptr %24, ptr %27)
  %81 = icmp ne i32 %80, 0
  br i1 %81, label %82, label %83, !prof !0

82:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 3)
  ret i32 1

83:
  %84 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 3
  %85 = load i64, ptr %84, align 8
  %86 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 1
  %87 = load i8, ptr %86, align 1
  %88 = icmp eq i8 %87, -1
  %89 = inttoptr i64 %85 to ptr
  %90 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 2
  %91 = select i1 %88, ptr %89, ptr %90
  %92 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 4
  %93 = load i64, ptr %92, align 8
  %94 = zext i8 %87 to i64
  %95 = select i1 %88, i64 %93, i64 %94
  %96 = insertvalue { ptr, i64 } poison, ptr %91, 0
  %97 = insertvalue { ptr, i64 } %96, i64 %95, 1
  %98 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %99 = ptrtoint ptr %98 to i64
  %100 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 3
  store i64 %99, ptr %100, align 8
  %101 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %102 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 4
  store i64 %101, ptr %102, align 8
  %103 = call i32 @luce_rt_new_list(ptr %1, ptr %28, ptr %31)
  %104 = icmp ne i32 %103, 0
  br i1 %104, label %105, label %106, !prof !0

105:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 4)
  ret i32 1

106:
  %107 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 3
  %108 = load i64, ptr %107, align 8
  %109 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 4 }, 0
  %110 = ptrtoint ptr %109 to i64
  %111 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 3
  store i64 %110, ptr %111, align 8
  %112 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 4 }, 1
  %113 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 4
  store i64 %112, ptr %113, align 8
  %114 = call i32 @luce_rt_own_storage(ptr %1, ptr %32, ptr %35)
  %115 = icmp ne i32 %114, 0
  br i1 %115, label %116, label %117, !prof !0

116:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 5)
  ret i32 1

117:
  %118 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 3
  %119 = load i64, ptr %118, align 8
  %120 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 1
  %121 = load i8, ptr %120, align 1
  %122 = icmp eq i8 %121, -1
  %123 = inttoptr i64 %119 to ptr
  %124 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 2
  %125 = select i1 %122, ptr %123, ptr %124
  %126 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 4
  %127 = load i64, ptr %126, align 8
  %128 = zext i8 %121 to i64
  %129 = select i1 %122, i64 %127, i64 %128
  %130 = insertvalue { ptr, i64 } poison, ptr %125, 0
  %131 = insertvalue { ptr, i64 } %130, i64 %129, 1
  %132 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 3
  store i64 %108, ptr %132, align 8
  %133 = call i32 @luce_rt_append(ptr %1, ptr %36, ptr %35)
  %134 = icmp ne i32 %133, 0
  br i1 %134, label %135, label %136, !prof !0

135:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 6)
  ret i32 1

136:
  %137 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 3
  store i64 %108, ptr %137, align 8
  %138 = call i32 @luce_rt_append(ptr %1, ptr %39, ptr %27)
  %139 = icmp ne i32 %138, 0
  br i1 %139, label %140, label %141, !prof !0

140:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 7)
  ret i32 1

141:
  store i64 %108, ptr %8, align 8
  %142 = load i64, ptr %8, align 8
  %143 = icmp slt i64 %42, 1
  br i1 %143, label %144, label %147, !prof !0

144:
  %145 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 19 }, 0
  %146 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %145, i64 %146)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 11)
  ret i32 1

147:
  %148 = call i32 @luce.1.strings.join(ptr %0, ptr %1, i64 %42, i64 %142, { ptr, i64 } { ptr @luce.text.4, i64 1 }, ptr %43)
  %149 = icmp ne i32 %148, 0
  br i1 %149, label %150, label %151, !prof !0

150:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 11)
  ret i32 1

151:
  %152 = load { ptr, i64 }, ptr %43, align 8
  %153 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 0
  store i8 4, ptr %153, align 1
  %154 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  store i8 -1, ptr %154, align 1
  %155 = extractvalue { ptr, i64 } %152, 0
  %156 = ptrtoint ptr %155 to i64
  %157 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  store i64 %156, ptr %157, align 8
  %158 = extractvalue { ptr, i64 } %152, 1
  %159 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  store i64 %158, ptr %159, align 8
  %160 = extractvalue { ptr, i64 } %152, 0
  %161 = extractvalue { ptr, i64 } %152, 1
  %162 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %163 = load ptr, ptr %162, align 8
  %164 = icmp eq ptr %163, null
  br i1 %164, label %165, label %168, !prof !0

165:
  %166 = extractvalue { ptr, i64 } { ptr @luce.text.6, i64 24 }, 0
  %167 = extractvalue { ptr, i64 } { ptr @luce.text.6, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %166, i64 %167)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 13)
  ret i32 1

168:
  %169 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %170 = load ptr, ptr %169, align 8
  %171 = call i32 %163(ptr %170, ptr %160, i64 %161)
  %172 = icmp eq i32 %171, -1
  br i1 %172, label %173, label %174, !prof !0

173:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

174:
  %175 = icmp ne i32 %171, 0
  %176 = icmp ne i32 %171, 1
  %177 = and i1 %175, %176
  br i1 %177, label %178, label %181, !prof !0

178:
  %179 = extractvalue { ptr, i64 } { ptr @luce.text.6, i64 24 }, 0
  %180 = extractvalue { ptr, i64 } { ptr @luce.text.6, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %179, i64 %180)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 13)
  ret i32 1

181:
  %182 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %183 = load i64, ptr %182, align 8
  %184 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  %185 = load i8, ptr %184, align 1
  %186 = icmp eq i8 %185, -1
  %187 = inttoptr i64 %183 to ptr
  %188 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 2
  %189 = select i1 %186, ptr %187, ptr %188
  %190 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  %191 = load i64, ptr %190, align 8
  %192 = zext i8 %185 to i64
  %193 = select i1 %186, i64 %191, i64 %192
  %194 = insertvalue { ptr, i64 } poison, ptr %189, 0
  %195 = insertvalue { ptr, i64 } %194, i64 %193, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %9, ptr %44)
  %196 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 3
  %197 = load i64, ptr %196, align 8
  %198 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 1
  %199 = load i8, ptr %198, align 1
  %200 = icmp eq i8 %199, -1
  %201 = inttoptr i64 %197 to ptr
  %202 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 2
  %203 = select i1 %200, ptr %201, ptr %202
  %204 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 4
  %205 = load i64, ptr %204, align 8
  %206 = zext i8 %199 to i64
  %207 = select i1 %200, i64 %205, i64 %206
  %208 = insertvalue { ptr, i64 } poison, ptr %203, 0
  %209 = insertvalue { ptr, i64 } %208, i64 %207, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %44, i64 24, i1 false)
  %210 = load i64, ptr %8, align 8
  %211 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 3
  store i64 %210, ptr %211, align 8
  %212 = call i32 @luce_rt_release(ptr %1, ptr %45)
  %213 = icmp ne i32 %212, 0
  br i1 %213, label %214, label %215, !prof !0

214:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 18)
  ret i32 1

215:
  ret i32 0
}

define internal i32 @luce.1.strings.join(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3, { ptr, i64 } %4, ptr align 8 nocapture nonnull dereferenceable(16) writeonly noundef %5) {
6:
  %7 = alloca i64, align 8
  %8 = alloca { ptr, i64 }, align 8
  %9 = alloca i64, align 8
  %10 = alloca i64, align 8
  %11 = alloca i64, align 8
  %12 = alloca i64, align 8
  %13 = alloca i64, align 8
  %14 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %15 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %7, align 8
  store { ptr, i64 } %4, ptr %8, align 8
  store i64 4294967295, ptr %9, align 8
  store i64 4294967295, ptr %10, align 8
  store i64 4294967295, ptr %11, align 8
  store i64 0, ptr %12, align 8
  store i64 0, ptr %13, align 8
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 0
  store i8 4, ptr %16, align 1
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 1
  store i8 -1, ptr %17, align 1
  %18 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %19 = ptrtoint ptr %18 to i64
  %20 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 3
  store i64 %19, ptr %20, align 8
  %21 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %22 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 4
  store i64 %21, ptr %22, align 8
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %15, i32 0, i32 0
  store i8 4, ptr %23, align 1
  %24 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %15, i32 0, i32 1
  store i8 -1, ptr %24, align 1
  %25 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %26 = ptrtoint ptr %25 to i64
  %27 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %15, i32 0, i32 3
  store i64 %26, ptr %27, align 8
  %28 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %29 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %15, i32 0, i32 4
  store i64 %28, ptr %29, align 8
  %30 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %31 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %32 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %33 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 0
  store i8 4, ptr %33, align 1
  %34 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 1
  store i8 -1, ptr %34, align 1
  %35 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %36 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %37 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %38 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %37, i32 0, i32 0
  store i8 6, ptr %38, align 1
  %39 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %37, i32 0, i32 4
  store i64 0, ptr %39, align 8
  %40 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %41 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %42 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %43 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 0
  store i8 6, ptr %43, align 1
  %44 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 4
  store i64 0, ptr %44, align 8
  %45 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %46 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 0
  store i8 6, ptr %46, align 1
  %47 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 4
  store i64 0, ptr %47, align 8
  %48 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %49 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 0
  store i8 4, ptr %49, align 1
  %50 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 1
  store i8 -1, ptr %50, align 1
  %51 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %52 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %51, i32 0, i32 0
  store i8 6, ptr %52, align 1
  %53 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %51, i32 0, i32 4
  store i64 0, ptr %53, align 8
  br label %54

54:
  %55 = call i32 @luce_rt_new_builder(ptr %1, ptr %30)
  %56 = icmp ne i32 %55, 0
  br i1 %56, label %139, label %140, !prof !0

57:
  %58 = load i64, ptr %11, align 8
  %59 = trunc i64 %58 to i32
  %60 = lshr i64 %58, 32
  %61 = trunc i64 %60 to i32
  %62 = icmp eq i32 %59, -1
  br i1 %62, label %144, label %147, !prof !0

63:
  %64 = load i64, ptr %12, align 8
  store i64 %64, ptr %13, align 8
  %65 = load i64, ptr %11, align 8
  %66 = load i64, ptr %12, align 8
  %67 = trunc i64 %65 to i32
  %68 = lshr i64 %65, 32
  %69 = trunc i64 %68 to i32
  %70 = icmp eq i32 %67, -1
  br i1 %70, label %171, label %174, !prof !0

71:
  %72 = load i64, ptr %12, align 8
  %73 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %72, i64 1)
  %74 = extractvalue { i64, i1 } %73, 0
  %75 = extractvalue { i64, i1 } %73, 1
  br i1 %75, label %273, label %276, !prof !0

76:
  %77 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 3
  %78 = load i64, ptr %77, align 8
  %79 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 1
  %80 = load i8, ptr %79, align 1
  %81 = icmp eq i8 %80, -1
  %82 = inttoptr i64 %78 to ptr
  %83 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 2
  %84 = select i1 %81, ptr %82, ptr %83
  %85 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 4
  %86 = load i64, ptr %85, align 8
  %87 = zext i8 %80 to i64
  %88 = select i1 %81, i64 %86, i64 %87
  %89 = insertvalue { ptr, i64 } poison, ptr %84, 0
  %90 = insertvalue { ptr, i64 } %89, i64 %88, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %14, ptr %36)
  %91 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 3
  %92 = load i64, ptr %91, align 8
  %93 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 1
  %94 = load i8, ptr %93, align 1
  %95 = icmp eq i8 %94, -1
  %96 = inttoptr i64 %92 to ptr
  %97 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 2
  %98 = select i1 %95, ptr %96, ptr %97
  %99 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 4
  %100 = load i64, ptr %99, align 8
  %101 = zext i8 %94 to i64
  %102 = select i1 %95, i64 %100, i64 %101
  %103 = insertvalue { ptr, i64 } poison, ptr %98, 0
  %104 = insertvalue { ptr, i64 } %103, i64 %102, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %14, ptr align 8 %36, i64 24, i1 false)
  %105 = load i64, ptr %10, align 8
  %106 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %37, i32 0, i32 3
  store i64 %105, ptr %106, align 8
  %107 = call i32 @luce_rt_str(ptr %1, ptr %37, ptr %40)
  %108 = icmp ne i32 %107, 0
  br i1 %108, label %277, label %278, !prof !0

109:
  %110 = load i64, ptr %10, align 8
  %111 = load { ptr, i64 }, ptr %8, align 8
  %112 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 3
  store i64 %110, ptr %112, align 8
  %113 = extractvalue { ptr, i64 } %111, 0
  %114 = ptrtoint ptr %113 to i64
  %115 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 3
  store i64 %114, ptr %115, align 8
  %116 = extractvalue { ptr, i64 } %111, 1
  %117 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 4
  store i64 %116, ptr %117, align 8
  %118 = call i32 @luce_rt_append(ptr %1, ptr %45, ptr %48)
  %119 = icmp ne i32 %118, 0
  br i1 %119, label %317, label %318, !prof !0

120:
  %121 = load i64, ptr %10, align 8
  %122 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 3
  %123 = load i64, ptr %122, align 8
  %124 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 1
  %125 = load i8, ptr %124, align 1
  %126 = icmp eq i8 %125, -1
  %127 = inttoptr i64 %123 to ptr
  %128 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 2
  %129 = select i1 %126, ptr %127, ptr %128
  %130 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 4
  %131 = load i64, ptr %130, align 8
  %132 = zext i8 %125 to i64
  %133 = select i1 %126, i64 %131, i64 %132
  %134 = insertvalue { ptr, i64 } poison, ptr %129, 0
  %135 = insertvalue { ptr, i64 } %134, i64 %133, 1
  %136 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %51, i32 0, i32 3
  store i64 %121, ptr %136, align 8
  %137 = call i32 @luce_rt_append(ptr %1, ptr %51, ptr %14)
  %138 = icmp ne i32 %137, 0
  br i1 %138, label %319, label %320, !prof !0

139:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 0)
  ret i32 1

140:
  %141 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 3
  %142 = load i64, ptr %141, align 8
  store i64 %142, ptr %10, align 8
  %143 = load i64, ptr %7, align 8
  store i64 %143, ptr %11, align 8
  store i64 0, ptr %12, align 8
  br label %57

144:
  %145 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 0
  %146 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %145, i64 %146)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 8)
  ret i32 1

147:
  %148 = getelementptr inbounds i8, ptr %1, i64 96
  %149 = load ptr, ptr %148, align 8!alias.scope !1, !noalias !2
  %150 = zext i32 %59 to i64
  %151 = mul nsw i64 %150, 112
  %152 = getelementptr inbounds i8, ptr %149, i64 %151
  %153 = getelementptr inbounds i8, ptr %152, i64 96
  %154 = load i32, ptr %153, align 4, !alias.scope !1, !noalias !2
  %155 = icmp ne i32 %154, %61
  br i1 %155, label %156, label %159, !prof !0

156:
  %157 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %158 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %157, i64 %158)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 8)
  ret i32 1

159:
  %160 = and i32 %154, 1
  %161 = icmp ne i32 %160, 0
  br i1 %161, label %162, label %165, !prof !0

162:
  %163 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %164 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %163, i64 %164)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 8)
  ret i32 1

165:
  %166 = getelementptr inbounds i8, ptr %152, i64 16
  %167 = load i64, ptr %166, align 8!alias.scope !1, !noalias !2
  %168 = load ptr, ptr %152, align 8, !alias.scope !1, !noalias !2
  %169 = load i64, ptr %12, align 8
  %170 = icmp slt i64 %169, %167
  br i1 %170, label %63, label %76

171:
  %172 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 0
  %173 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %172, i64 %173)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 16)
  ret i32 1

174:
  %175 = getelementptr inbounds i8, ptr %1, i64 96
  %176 = load ptr, ptr %175, align 8!alias.scope !1, !noalias !2
  %177 = zext i32 %67 to i64
  %178 = mul nsw i64 %177, 112
  %179 = getelementptr inbounds i8, ptr %176, i64 %178
  %180 = getelementptr inbounds i8, ptr %179, i64 96
  %181 = load i32, ptr %180, align 4, !alias.scope !1, !noalias !2
  %182 = icmp ne i32 %181, %69
  br i1 %182, label %183, label %186, !prof !0

183:
  %184 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %185 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %184, i64 %185)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 16)
  ret i32 1

186:
  %187 = and i32 %181, 1
  %188 = icmp ne i32 %187, 0
  br i1 %188, label %189, label %192, !prof !0

189:
  %190 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %191 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %190, i64 %191)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 16)
  ret i32 1

192:
  %193 = getelementptr inbounds i8, ptr %179, i64 16
  %194 = load i64, ptr %193, align 8!alias.scope !1, !noalias !2
  %195 = load ptr, ptr %179, align 8, !alias.scope !1, !noalias !2
  %196 = icmp slt i64 %66, 0
  %197 = icmp sge i64 %66, %194
  %198 = or i1 %196, %197
  br i1 %198, label %199, label %202, !prof !0

199:
  %200 = extractvalue { ptr, i64 } { ptr @luce.text.7, i64 19 }, 0
  %201 = extractvalue { ptr, i64 } { ptr @luce.text.7, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 10, ptr %200, i64 %201)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 16)
  ret i32 1

202:
  %203 = mul nsw i64 0, %194
  %204 = add nsw i64 %203, %66
  %205 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %195, i64 %204
  %206 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %205, i32 0, i32 3
  %207 = load i64, ptr %206, align 8
  %208 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %205, i32 0, i32 1
  %209 = load i8, ptr %208, align 1
  %210 = icmp eq i8 %209, -1
  %211 = inttoptr i64 %207 to ptr
  %212 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %205, i32 0, i32 2
  %213 = select i1 %210, ptr %211, ptr %212
  %214 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %205, i32 0, i32 4
  %215 = load i64, ptr %214, align 8
  %216 = zext i8 %209 to i64
  %217 = select i1 %210, i64 %215, i64 %216
  %218 = insertvalue { ptr, i64 } poison, ptr %213, 0
  %219 = insertvalue { ptr, i64 } %218, i64 %217, 1
  %220 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 3
  %221 = load i64, ptr %220, align 8
  %222 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 1
  %223 = load i8, ptr %222, align 1
  %224 = icmp eq i8 %223, -1
  %225 = inttoptr i64 %221 to ptr
  %226 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 2
  %227 = select i1 %224, ptr %225, ptr %226
  %228 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %14, i32 0, i32 4
  %229 = load i64, ptr %228, align 8
  %230 = zext i8 %223 to i64
  %231 = select i1 %224, i64 %229, i64 %230
  %232 = insertvalue { ptr, i64 } poison, ptr %227, 0
  %233 = insertvalue { ptr, i64 } %232, i64 %231, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %14, ptr %31)
  %234 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 3
  %235 = load i64, ptr %234, align 8
  %236 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 1
  %237 = load i8, ptr %236, align 1
  %238 = icmp eq i8 %237, -1
  %239 = inttoptr i64 %235 to ptr
  %240 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 2
  %241 = select i1 %238, ptr %239, ptr %240
  %242 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %31, i32 0, i32 4
  %243 = load i64, ptr %242, align 8
  %244 = zext i8 %237 to i64
  %245 = select i1 %238, i64 %243, i64 %244
  %246 = insertvalue { ptr, i64 } poison, ptr %241, 0
  %247 = insertvalue { ptr, i64 } %246, i64 %245, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %14, ptr align 8 %31, i64 24, i1 false)
  %248 = extractvalue { ptr, i64 } %219, 0
  %249 = ptrtoint ptr %248 to i64
  %250 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 3
  store i64 %249, ptr %250, align 8
  %251 = extractvalue { ptr, i64 } %219, 1
  %252 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %32, i32 0, i32 4
  store i64 %251, ptr %252, align 8
  %253 = call i32 @luce_rt_own_storage(ptr %1, ptr %32, ptr %35)
  %254 = icmp ne i32 %253, 0
  br i1 %254, label %255, label %256, !prof !0

255:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 20)
  ret i32 1

256:
  %257 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 3
  %258 = load i64, ptr %257, align 8
  %259 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 1
  %260 = load i8, ptr %259, align 1
  %261 = icmp eq i8 %260, -1
  %262 = inttoptr i64 %258 to ptr
  %263 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 2
  %264 = select i1 %261, ptr %262, ptr %263
  %265 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 4
  %266 = load i64, ptr %265, align 8
  %267 = zext i8 %260 to i64
  %268 = select i1 %261, i64 %266, i64 %267
  %269 = insertvalue { ptr, i64 } poison, ptr %264, 0
  %270 = insertvalue { ptr, i64 } %269, i64 %268, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %14, ptr align 8 %35, i64 24, i1 false)
  %271 = load i64, ptr %13, align 8
  %272 = icmp sgt i64 %271, 0
  br i1 %272, label %109, label %120

273:
  %274 = extractvalue { ptr, i64 } { ptr @luce.text.8, i64 16 }, 0
  %275 = extractvalue { ptr, i64 } { ptr @luce.text.8, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %274, i64 %275)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 36)
  ret i32 1

276:
  store i64 %74, ptr %12, align 8
  br label %57

277:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 43)
  ret i32 1

278:
  %279 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %40, i32 0, i32 3
  %280 = load i64, ptr %279, align 8
  %281 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %40, i32 0, i32 1
  %282 = load i8, ptr %281, align 1
  %283 = icmp eq i8 %282, -1
  %284 = inttoptr i64 %280 to ptr
  %285 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %40, i32 0, i32 2
  %286 = select i1 %283, ptr %284, ptr %285
  %287 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %40, i32 0, i32 4
  %288 = load i64, ptr %287, align 8
  %289 = zext i8 %282 to i64
  %290 = select i1 %283, i64 %288, i64 %289
  %291 = insertvalue { ptr, i64 } poison, ptr %286, 0
  %292 = insertvalue { ptr, i64 } %291, i64 %290, 1
  %293 = call i32 @luce_rt_export_storage(ptr %1, ptr %40, ptr %41)
  %294 = icmp ne i32 %293, 0
  br i1 %294, label %295, label %296, !prof !0

295:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 44)
  ret i32 1

296:
  %297 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 3
  %298 = load i64, ptr %297, align 8
  %299 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 1
  %300 = load i8, ptr %299, align 1
  %301 = icmp eq i8 %300, -1
  %302 = inttoptr i64 %298 to ptr
  %303 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 2
  %304 = select i1 %301, ptr %302, ptr %303
  %305 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 4
  %306 = load i64, ptr %305, align 8
  %307 = zext i8 %300 to i64
  %308 = select i1 %301, i64 %306, i64 %307
  %309 = insertvalue { ptr, i64 } poison, ptr %304, 0
  %310 = insertvalue { ptr, i64 } %309, i64 %308, 1
  %311 = load i64, ptr %10, align 8
  %312 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 3
  store i64 %311, ptr %312, align 8
  %313 = call i32 @luce_rt_release(ptr %1, ptr %42)
  %314 = icmp ne i32 %313, 0
  br i1 %314, label %315, label %316, !prof !0

315:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 46)
  ret i32 1

316:
  store { ptr, i64 } %310, ptr %5, align 8
  ret i32 0

317:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 28)
  ret i32 1

318:
  br label %120

319:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 32)
  ret i32 1

320:
  br label %71
}

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #0

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #1

; Function Attrs: nounwind willreturn memory(readwrite)
declare i32 @luce_rt_new_list(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #2

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_own_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

; Function Attrs: nounwind willreturn memory(readwrite)
declare i32 @luce_rt_append(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %2) #2

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #4

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #5

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #6

; Function Attrs: nounwind willreturn memory(readwrite)
declare i32 @luce_rt_new_builder(ptr nocapture nonnull noundef %0, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %1) #2

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %0, i64 %1) #7

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_export_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

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
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.5, i64 19)
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
declare noalias ptr @luce_rt_open(ptr readonly %0, i64 %1) #8

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_files_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9, ptr %10, ptr %11) #9

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #2

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #9

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
attributes #1 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #2 = { nounwind willreturn memory(readwrite) }
attributes #3 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #4 = { nounwind cold willreturn memory(argmem: write) }
attributes #5 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #6 = { nounwind memory(readwrite) }
attributes #7 = { nounwind speculatable willreturn nofree nosync nocallback memory(none) }
attributes #8 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #9 = { nounwind willreturn memory(argmem: readwrite) }
attributes #10 = { cold }
attributes #11 = { nounwind willreturn memory(argmem: read) }

!0 = !{!"branch_weights", i32 1, i32 2000}
!1 = !{!3}
!2 = !{!4}
!3 = !{!"luce.rows", !5}
!4 = !{!"luce.elements", !5}
!5 = !{!"luce.alias"}
