; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/structures.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/structures.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.1 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.2 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.3 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce.text.4 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.5 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.6 = private unnamed_addr constant [4 x i8] c"main"
@luce.text.7 = private unnamed_addr constant [61 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/structures.luc"
@luce.origins.0 = private constant [28 x { i32, i32 }] [{ i32, i32 } { i32 9, i32 5 }, { i32, i32 } { i32 9, i32 5 }, { i32, i32 } { i32 9, i32 5 }, { i32, i32 } { i32 9, i32 5 }, { i32, i32 } { i32 9, i32 5 }, { i32, i32 } { i32 10, i32 5 }, { i32, i32 } { i32 10, i32 5 }, { i32, i32 } { i32 10, i32 5 }, { i32, i32 } { i32 10, i32 5 }, { i32, i32 } { i32 10, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }, { i32, i32 } { i32 11, i32 5 }]
@luce.text.8 = private unnamed_addr constant [11 x i8] c"Point.moved"
@luce.origins.1 = private constant [10 x { i32, i32 }] [{ i32, i32 } { i32 6, i32 9 }, { i32, i32 } { i32 6, i32 9 }, { i32, i32 } { i32 6, i32 9 }, { i32, i32 } { i32 6, i32 9 }, { i32, i32 } { i32 6, i32 9 }, { i32, i32 } { i32 6, i32 9 }, { i32, i32 } { i32 6, i32 9 }, { i32, i32 } { i32 6, i32 9 }, { i32, i32 } { i32 6, i32 9 }, { i32, i32 } { i32 6, i32 9 }]
@luce.functions = private constant [2 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.6, i64 4, ptr @luce.text.7, i64 61, ptr @luce.origins.0, i64 28 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.8, i64 11, ptr @luce.text.7, i64 61, ptr @luce.origins.1, i64 10 }]
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %7 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %8 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %9 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %10 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 0
  store i8 5, ptr %11, align 1
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 4
  store i64 2, ptr %12, align 8
  %13 = ptrtoint ptr null to i64
  %14 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 3
  store i64 %13, ptr %14, align 8
  %15 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 0
  store i8 5, ptr %15, align 1
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  store i64 2, ptr %16, align 8
  %17 = ptrtoint ptr null to i64
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  store i64 %17, ptr %18, align 8
  %19 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 0
  store i8 5, ptr %19, align 1
  %20 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  store i64 2, ptr %20, align 8
  %21 = ptrtoint ptr null to i64
  %22 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  store i64 %21, ptr %22, align 8
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 0
  store i8 5, ptr %23, align 1
  %24 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  store i64 2, ptr %24, align 8
  %25 = ptrtoint ptr null to i64
  %26 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  store i64 %25, ptr %26, align 8
  %27 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 0
  store i8 4, ptr %27, align 1
  %28 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 1
  store i8 -1, ptr %28, align 1
  %29 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %30 = ptrtoint ptr %29 to i64
  %31 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 3
  store i64 %30, ptr %31, align 8
  %32 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %33 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 4
  store i64 %32, ptr %33, align 8
  %34 = alloca { i8, i8, [6 x i8], i64, i64 },i64 2, align 8
  %35 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %34, i64 0
  %36 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 0
  store i8 2, ptr %36, align 1
  %37 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 4
  store i64 0, ptr %37, align 8
  %38 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %34, i64 1
  %39 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 0
  store i8 2, ptr %39, align 1
  %40 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 4
  store i64 0, ptr %40, align 8
  %41 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %42 = sub nsw i64 %2, 1
  %43 = alloca ptr, align 8
  %44 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %45 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 0
  store i8 2, ptr %45, align 1
  %46 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 4
  store i64 0, ptr %46, align 8
  %47 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %48 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %49 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %50 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %51

51:
  %52 = load i64, ptr %5, align 8
  %53 = trunc i64 %52 to i32
  %54 = lshr i64 %52, 32
  %55 = trunc i64 %54 to i32
  %56 = icmp eq i32 %53, -1
  br i1 %56, label %57, label %60, !prof !0

57:
  %58 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %59 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %58, i64 %59)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

60:
  %61 = getelementptr inbounds i8, ptr %1, i64 96
  %62 = load ptr, ptr %61, align 8!alias.scope !1, !noalias !2
  %63 = zext i32 %53 to i64
  %64 = mul nsw i64 %63, 112
  %65 = getelementptr inbounds i8, ptr %62, i64 %64
  %66 = getelementptr inbounds i8, ptr %65, i64 96
  %67 = load i32, ptr %66, align 4, !alias.scope !1, !noalias !2
  %68 = icmp ne i32 %67, %55
  br i1 %68, label %69, label %72, !prof !0

69:
  %70 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %71 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %70, i64 %71)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

72:
  %73 = and i32 %67, 1
  %74 = icmp ne i32 %73, 0
  br i1 %74, label %75, label %78, !prof !0

75:
  %76 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %77 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %76, i64 %77)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

78:
  %79 = getelementptr inbounds i8, ptr %65, i64 16
  %80 = load i64, ptr %79, align 8!alias.scope !1, !noalias !2
  %81 = load ptr, ptr %65, align 8, !alias.scope !1, !noalias !2
  %82 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %35, i32 0, i32 3
  store i64 %80, ptr %82, align 8
  %83 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 3
  store i64 2, ptr %83, align 8
  %84 = call i32 @luce_rt_struct_make(ptr %1, ptr %34, i64 2, ptr %41)
  %85 = icmp ne i32 %84, 0
  br i1 %85, label %86, label %87, !prof !0

86:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 3)
  ret i32 1

87:
  %88 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 3
  %89 = load i64, ptr %88, align 8
  %90 = inttoptr i64 %89 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %7, ptr align 8 %41, i64 24, i1 false)
  %91 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %92 = load i64, ptr %91, align 8
  %93 = inttoptr i64 %92 to ptr
  %94 = icmp slt i64 %42, 1
  br i1 %94, label %95, label %98, !prof !0

95:
  %96 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 0
  %97 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 6, ptr %96, i64 %97)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 8)
  ret i32 1

98:
  %99 = call i32 @luce.1.Point.moved(ptr %0, ptr %1, i64 %42, ptr %93, i64 3, i64 4, ptr %43)
  %100 = icmp ne i32 %99, 0
  br i1 %100, label %101, label %102, !prof !0

101:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 8)
  ret i32 1

102:
  %103 = load ptr, ptr %43, align 8
  %104 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 0
  store i8 5, ptr %104, align 1
  %105 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  store i64 2, ptr %105, align 8
  %106 = ptrtoint ptr %103 to i64
  %107 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  store i64 %106, ptr %107, align 8
  %108 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %109 = load i64, ptr %108, align 8
  %110 = inttoptr i64 %109 to ptr
  %111 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %110, i64 0
  %112 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %111, i32 0, i32 3
  %113 = load i64, ptr %112, align 8
  %114 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %115 = load i64, ptr %114, align 8
  %116 = inttoptr i64 %115 to ptr
  %117 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %116, i64 1
  %118 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %117, i32 0, i32 3
  %119 = load i64, ptr %118, align 8
  %120 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %113, i64 %119)
  %121 = extractvalue { i64, i1 } %120, 0
  %122 = extractvalue { i64, i1 } %120, 1
  br i1 %122, label %123, label %126, !prof !0

123:
  %124 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 0
  %125 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %124, i64 %125)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 14)
  ret i32 1

126:
  %127 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 3
  store i64 %121, ptr %127, align 8
  %128 = call i32 @luce_rt_str(ptr %1, ptr %44, ptr %47)
  %129 = icmp ne i32 %128, 0
  br i1 %129, label %130, label %131, !prof !0

130:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 15)
  ret i32 1

131:
  %132 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %47, i32 0, i32 3
  %133 = load i64, ptr %132, align 8
  %134 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %47, i32 0, i32 1
  %135 = load i8, ptr %134, align 1
  %136 = icmp eq i8 %135, -1
  %137 = inttoptr i64 %133 to ptr
  %138 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %47, i32 0, i32 2
  %139 = select i1 %136, ptr %137, ptr %138
  %140 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %47, i32 0, i32 4
  %141 = load i64, ptr %140, align 8
  %142 = zext i8 %135 to i64
  %143 = select i1 %136, i64 %141, i64 %142
  %144 = insertvalue { ptr, i64 } poison, ptr %139, 0
  %145 = insertvalue { ptr, i64 } %144, i64 %143, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %10, ptr align 8 %47, i64 24, i1 false)
  %146 = extractvalue { ptr, i64 } %145, 0
  %147 = extractvalue { ptr, i64 } %145, 1
  %148 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %149 = load ptr, ptr %148, align 8
  %150 = icmp eq ptr %149, null
  br i1 %150, label %151, label %154, !prof !0

151:
  %152 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %153 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %152, i64 %153)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 17)
  ret i32 1

154:
  %155 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %156 = load ptr, ptr %155, align 8
  %157 = call i32 %149(ptr %156, ptr %146, i64 %147)
  %158 = icmp eq i32 %157, -1
  br i1 %158, label %159, label %160, !prof !0

159:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

160:
  %161 = icmp ne i32 %157, 0
  %162 = icmp ne i32 %157, 1
  %163 = and i1 %161, %162
  br i1 %163, label %164, label %167, !prof !0

164:
  %165 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %166 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %165, i64 %166)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 17)
  ret i32 1

167:
  %168 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 3
  %169 = load i64, ptr %168, align 8
  %170 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 1
  %171 = load i8, ptr %170, align 1
  %172 = icmp eq i8 %171, -1
  %173 = inttoptr i64 %169 to ptr
  %174 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 2
  %175 = select i1 %172, ptr %173, ptr %174
  %176 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 4
  %177 = load i64, ptr %176, align 8
  %178 = zext i8 %171 to i64
  %179 = select i1 %172, i64 %177, i64 %178
  %180 = insertvalue { ptr, i64 } poison, ptr %175, 0
  %181 = insertvalue { ptr, i64 } %180, i64 %179, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %10, ptr %48)
  %182 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 3
  %183 = load i64, ptr %182, align 8
  %184 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 1
  %185 = load i8, ptr %184, align 1
  %186 = icmp eq i8 %185, -1
  %187 = inttoptr i64 %183 to ptr
  %188 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 2
  %189 = select i1 %186, ptr %187, ptr %188
  %190 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 4
  %191 = load i64, ptr %190, align 8
  %192 = zext i8 %185 to i64
  %193 = select i1 %186, i64 %191, i64 %192
  %194 = insertvalue { ptr, i64 } poison, ptr %189, 0
  %195 = insertvalue { ptr, i64 } %194, i64 %193, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %10, ptr align 8 %48, i64 24, i1 false)
  %196 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %197 = load i64, ptr %196, align 8
  %198 = inttoptr i64 %197 to ptr
  call void @luce_rt_drop_storage(ptr %1, ptr %9, ptr %49)
  %199 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %49, i32 0, i32 3
  %200 = load i64, ptr %199, align 8
  %201 = inttoptr i64 %200 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %49, i64 24, i1 false)
  %202 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %203 = load i64, ptr %202, align 8
  %204 = inttoptr i64 %203 to ptr
  call void @luce_rt_drop_storage(ptr %1, ptr %7, ptr %50)
  %205 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 3
  %206 = load i64, ptr %205, align 8
  %207 = inttoptr i64 %206 to ptr
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %7, ptr align 8 %50, i64 24, i1 false)
  ret i32 0
}

define internal i32 @luce.1.Point.moved(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, ptr align 8 readonly nonnull noundef %3, i64 %4, i64 %5, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %6) {
7:
  %8 = alloca ptr, align 8
  %9 = alloca i64, align 8
  %10 = alloca i64, align 8
  %11 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store ptr %3, ptr %8, align 8
  store i64 %4, ptr %9, align 8
  store i64 %5, ptr %10, align 8
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %11, i32 0, i32 0
  store i8 5, ptr %12, align 1
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %11, i32 0, i32 4
  store i64 2, ptr %13, align 8
  %14 = ptrtoint ptr null to i64
  %15 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %11, i32 0, i32 3
  store i64 %14, ptr %15, align 8
  %16 = alloca { i8, i8, [6 x i8], i64, i64 },i64 2, align 8
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %16, i64 0
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 0
  store i8 2, ptr %18, align 1
  %19 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 4
  store i64 0, ptr %19, align 8
  %20 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %16, i64 1
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 0
  store i8 2, ptr %21, align 1
  %22 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 4
  store i64 0, ptr %22, align 8
  %23 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %24

24:
  %25 = load ptr, ptr %8, align 8
  %26 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i64 0
  %27 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %26, i32 0, i32 3
  %28 = load i64, ptr %27, align 8
  %29 = load i64, ptr %9, align 8
  %30 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %28, i64 %29)
  %31 = extractvalue { i64, i1 } %30, 0
  %32 = extractvalue { i64, i1 } %30, 1
  br i1 %32, label %33, label %36, !prof !0

33:
  %34 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 0
  %35 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %34, i64 %35)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 3)
  ret i32 1

36:
  %37 = load ptr, ptr %8, align 8
  %38 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %37, i64 1
  %39 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 3
  %40 = load i64, ptr %39, align 8
  %41 = load i64, ptr %10, align 8
  %42 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %40, i64 %41)
  %43 = extractvalue { i64, i1 } %42, 0
  %44 = extractvalue { i64, i1 } %42, 1
  br i1 %44, label %45, label %48, !prof !0

45:
  %46 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 0
  %47 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %46, i64 %47)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 7)
  ret i32 1

48:
  %49 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 3
  store i64 %31, ptr %49, align 8
  %50 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 3
  store i64 %43, ptr %50, align 8
  %51 = call i32 @luce_rt_struct_make(ptr %1, ptr %16, i64 2, ptr %23)
  %52 = icmp ne i32 %51, 0
  br i1 %52, label %53, label %54, !prof !0

53:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 8)
  ret i32 1

54:
  %55 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %23, i32 0, i32 3
  %56 = load i64, ptr %55, align 8
  %57 = inttoptr i64 %56 to ptr
  store ptr %57, ptr %6, align 8
  ret i32 0
}

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #0

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_struct_make(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull noundef %1, i64 %2, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %3) #1

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #2

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %0, i64 %1) #3

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #4

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #5

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #1

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
attributes #1 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #2 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #3 = { nounwind speculatable willreturn nofree nosync nocallback memory(none) }
attributes #4 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
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
