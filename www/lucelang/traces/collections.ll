; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/collections.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/collections.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.1 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.2 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.3 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.4 = private unnamed_addr constant [19 x i8] c"index out of bounds"
@luce.text.5 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.6 = private unnamed_addr constant [4 x i8] c"main"
@luce.text.7 = private unnamed_addr constant [62 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/collections.luc"
@luce.origins.0 = private constant [30 x { i32, i32 }] [{ i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }]
@luce.functions = private constant [1 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.6, i64 4, ptr @luce.text.7, i64 62, ptr @luce.origins.0, i64 30 }]
@luce.text.8 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
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
  %17 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 0
  store i8 2, ptr %18, align 1
  %19 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 4
  store i64 0, ptr %19, align 8
  %20 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %21 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %22 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %21, i32 0, i32 0
  store i8 6, ptr %22, align 1
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %21, i32 0, i32 4
  store i64 0, ptr %23, align 8
  %24 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %25 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %24, i32 0, i32 0
  store i8 2, ptr %25, align 1
  %26 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %24, i32 0, i32 4
  store i64 0, ptr %26, align 8
  %27 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %28 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 0
  store i8 6, ptr %28, align 1
  %29 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 4
  store i64 0, ptr %29, align 8
  %30 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %31 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 0
  store i8 2, ptr %31, align 1
  %32 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 4
  store i64 0, ptr %32, align 8
  %33 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %34 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %33, i32 0, i32 0
  store i8 6, ptr %34, align 1
  %35 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %33, i32 0, i32 4
  store i64 0, ptr %35, align 8
  %36 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %37 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 0
  store i8 6, ptr %37, align 1
  %38 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 4
  store i64 0, ptr %38, align 8
  %39 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %40 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 0
  store i8 2, ptr %40, align 1
  %41 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 4
  store i64 0, ptr %41, align 8
  %42 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %43 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 0
  store i8 2, ptr %43, align 1
  %44 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 4
  store i64 0, ptr %44, align 8
  %45 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %46 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %47 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %48 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %47, i32 0, i32 0
  store i8 6, ptr %48, align 1
  %49 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %47, i32 0, i32 4
  store i64 0, ptr %49, align 8
  %50 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %51 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 0
  store i8 6, ptr %51, align 1
  %52 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 4
  store i64 0, ptr %52, align 8
  br label %53

53:
  %54 = load i64, ptr %5, align 8
  %55 = trunc i64 %54 to i32
  %56 = lshr i64 %54, 32
  %57 = trunc i64 %56 to i32
  %58 = icmp eq i32 %55, -1
  br i1 %58, label %59, label %62, !prof !0

59:
  %60 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %61 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %60, i64 %61)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

62:
  %63 = getelementptr inbounds i8, ptr %1, i64 96
  %64 = load ptr, ptr %63, align 8!alias.scope !1, !noalias !2
  %65 = zext i32 %55 to i64
  %66 = mul nsw i64 %65, 112
  %67 = getelementptr inbounds i8, ptr %64, i64 %66
  %68 = getelementptr inbounds i8, ptr %67, i64 96
  %69 = load i32, ptr %68, align 4, !alias.scope !1, !noalias !2
  %70 = icmp ne i32 %69, %57
  br i1 %70, label %71, label %74, !prof !0

71:
  %72 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %73 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %72, i64 %73)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

74:
  %75 = and i32 %69, 1
  %76 = icmp ne i32 %75, 0
  br i1 %76, label %77, label %80, !prof !0

77:
  %78 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %79 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %78, i64 %79)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

80:
  %81 = getelementptr inbounds i8, ptr %67, i64 16
  %82 = load i64, ptr %81, align 8!alias.scope !1, !noalias !2
  %83 = load ptr, ptr %67, align 8, !alias.scope !1, !noalias !2
  %84 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 3
  store i64 0, ptr %84, align 8
  %85 = call i32 @luce_rt_new_list(ptr %1, ptr %17, ptr %20)
  %86 = icmp ne i32 %85, 0
  br i1 %86, label %87, label %88, !prof !0

87:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 3)
  ret i32 1

88:
  %89 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 3
  %90 = load i64, ptr %89, align 8
  %91 = trunc i64 %90 to i32
  %92 = lshr i64 %90, 32
  %93 = trunc i64 %92 to i32
  %94 = icmp eq i32 %91, -1
  br i1 %94, label %95, label %98, !prof !0

95:
  %96 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %97 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %96, i64 %97)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 4)
  ret i32 1

98:
  %99 = getelementptr inbounds i8, ptr %1, i64 96
  %100 = load ptr, ptr %99, align 8!alias.scope !1, !noalias !2
  %101 = zext i32 %91 to i64
  %102 = mul nsw i64 %101, 112
  %103 = getelementptr inbounds i8, ptr %100, i64 %102
  %104 = getelementptr inbounds i8, ptr %103, i64 96
  %105 = load i32, ptr %104, align 4, !alias.scope !1, !noalias !2
  %106 = icmp ne i32 %105, %93
  br i1 %106, label %107, label %110, !prof !0

107:
  %108 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %109 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %108, i64 %109)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 4)
  ret i32 1

110:
  %111 = and i32 %105, 1
  %112 = icmp ne i32 %111, 0
  br i1 %112, label %113, label %116, !prof !0

113:
  %114 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %115 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %114, i64 %115)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 4)
  ret i32 1

116:
  %117 = getelementptr inbounds i8, ptr %103, i64 16
  %118 = load i64, ptr %117, align 8!alias.scope !1, !noalias !2
  %119 = getelementptr inbounds i8, ptr %103, i64 8
  %120 = load i64, ptr %119, align 8, !alias.scope !1, !noalias !2
  %121 = add nuw i64 %118, 1
  %122 = mul nuw i64 %121, 8
  %123 = icmp ule i64 %122, %120
  br i1 %123, label %124, label %127, !prof !3

124:
  %125 = load ptr, ptr %103, align 8!alias.scope !1, !noalias !2
  %126 = getelementptr inbounds i64, ptr %125, i64 %118
  store i64 %82, ptr %126, align 8, !alias.scope !2, !noalias !1
  store i64 %121, ptr %117, align 8, !alias.scope !1, !noalias !2
  br label %132

127:
  %128 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %21, i32 0, i32 3
  store i64 %90, ptr %128, align 8
  %129 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %24, i32 0, i32 3
  store i64 %82, ptr %129, align 8
  %130 = call i32 @luce_rt_append(ptr %1, ptr %21, ptr %24)
  %131 = icmp ne i32 %130, 0
  br i1 %131, label %137, label %138, !prof !0

132:
  %133 = trunc i64 %90 to i32
  %134 = lshr i64 %90, 32
  %135 = trunc i64 %134 to i32
  %136 = icmp eq i32 %133, -1
  br i1 %136, label %139, label %142, !prof !0

137:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 4)
  ret i32 1

138:
  br label %132

139:
  %140 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %141 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %140, i64 %141)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 5)
  ret i32 1

142:
  %143 = getelementptr inbounds i8, ptr %1, i64 96
  %144 = load ptr, ptr %143, align 8!alias.scope !1, !noalias !2
  %145 = zext i32 %133 to i64
  %146 = mul nsw i64 %145, 112
  %147 = getelementptr inbounds i8, ptr %144, i64 %146
  %148 = getelementptr inbounds i8, ptr %147, i64 96
  %149 = load i32, ptr %148, align 4, !alias.scope !1, !noalias !2
  %150 = icmp ne i32 %149, %135
  br i1 %150, label %151, label %154, !prof !0

151:
  %152 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %153 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %152, i64 %153)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 5)
  ret i32 1

154:
  %155 = and i32 %149, 1
  %156 = icmp ne i32 %155, 0
  br i1 %156, label %157, label %160, !prof !0

157:
  %158 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %159 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %158, i64 %159)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 5)
  ret i32 1

160:
  %161 = getelementptr inbounds i8, ptr %147, i64 16
  %162 = load i64, ptr %161, align 8!alias.scope !1, !noalias !2
  %163 = getelementptr inbounds i8, ptr %147, i64 8
  %164 = load i64, ptr %163, align 8, !alias.scope !1, !noalias !2
  %165 = add nuw i64 %162, 1
  %166 = mul nuw i64 %165, 8
  %167 = icmp ule i64 %166, %164
  br i1 %167, label %168, label %171, !prof !3

168:
  %169 = load ptr, ptr %147, align 8!alias.scope !1, !noalias !2
  %170 = getelementptr inbounds i64, ptr %169, i64 %162
  store i64 2, ptr %170, align 8, !alias.scope !2, !noalias !1
  store i64 %165, ptr %161, align 8, !alias.scope !1, !noalias !2
  br label %176

171:
  %172 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 3
  store i64 %90, ptr %172, align 8
  %173 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 3
  store i64 2, ptr %173, align 8
  %174 = call i32 @luce_rt_append(ptr %1, ptr %27, ptr %30)
  %175 = icmp ne i32 %174, 0
  br i1 %175, label %181, label %182, !prof !0

176:
  store i64 %90, ptr %7, align 8
  %177 = load i64, ptr %7, align 8
  %178 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %33, i32 0, i32 3
  store i64 %177, ptr %178, align 8
  %179 = call i32 @luce_rt_retain(ptr %1, ptr %33)
  %180 = icmp ne i32 %179, 0
  br i1 %180, label %183, label %184, !prof !0

181:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 5)
  ret i32 1

182:
  br label %176

183:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 8)
  ret i32 1

184:
  store i64 %177, ptr %8, align 8
  %185 = load i64, ptr %8, align 8
  %186 = trunc i64 %185 to i32
  %187 = lshr i64 %185, 32
  %188 = trunc i64 %187 to i32
  %189 = icmp eq i32 %186, -1
  br i1 %189, label %190, label %193, !prof !0

190:
  %191 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %192 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %191, i64 %192)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 12)
  ret i32 1

193:
  %194 = getelementptr inbounds i8, ptr %1, i64 96
  %195 = load ptr, ptr %194, align 8!alias.scope !1, !noalias !2
  %196 = zext i32 %186 to i64
  %197 = mul nsw i64 %196, 112
  %198 = getelementptr inbounds i8, ptr %195, i64 %197
  %199 = getelementptr inbounds i8, ptr %198, i64 96
  %200 = load i32, ptr %199, align 4, !alias.scope !1, !noalias !2
  %201 = icmp ne i32 %200, %188
  br i1 %201, label %202, label %205, !prof !0

202:
  %203 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %204 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %203, i64 %204)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 12)
  ret i32 1

205:
  %206 = and i32 %200, 1
  %207 = icmp ne i32 %206, 0
  br i1 %207, label %208, label %211, !prof !0

208:
  %209 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %210 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %209, i64 %210)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 12)
  ret i32 1

211:
  %212 = getelementptr inbounds i8, ptr %198, i64 16
  %213 = load i64, ptr %212, align 8!alias.scope !1, !noalias !2
  %214 = getelementptr inbounds i8, ptr %198, i64 8
  %215 = load i64, ptr %214, align 8, !alias.scope !1, !noalias !2
  %216 = add nuw i64 %213, 1
  %217 = mul nuw i64 %216, 8
  %218 = icmp ule i64 %217, %215
  br i1 %218, label %219, label %222, !prof !3

219:
  %220 = load ptr, ptr %198, align 8!alias.scope !1, !noalias !2
  %221 = getelementptr inbounds i64, ptr %220, i64 %213
  store i64 3, ptr %221, align 8, !alias.scope !2, !noalias !1
  store i64 %216, ptr %212, align 8, !alias.scope !1, !noalias !2
  br label %227

222:
  %223 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 3
  store i64 %185, ptr %223, align 8
  %224 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 3
  store i64 3, ptr %224, align 8
  %225 = call i32 @luce_rt_append(ptr %1, ptr %36, ptr %39)
  %226 = icmp ne i32 %225, 0
  br i1 %226, label %234, label %235, !prof !0

227:
  %228 = load i64, ptr %7, align 8
  %229 = load i64, ptr %7, align 8
  %230 = trunc i64 %229 to i32
  %231 = lshr i64 %229, 32
  %232 = trunc i64 %231 to i32
  %233 = icmp eq i32 %230, -1
  br i1 %233, label %236, label %239, !prof !0

234:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 12)
  ret i32 1

235:
  br label %227

236:
  %237 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %238 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %237, i64 %238)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 15)
  ret i32 1

239:
  %240 = getelementptr inbounds i8, ptr %1, i64 96
  %241 = load ptr, ptr %240, align 8!alias.scope !1, !noalias !2
  %242 = zext i32 %230 to i64
  %243 = mul nsw i64 %242, 112
  %244 = getelementptr inbounds i8, ptr %241, i64 %243
  %245 = getelementptr inbounds i8, ptr %244, i64 96
  %246 = load i32, ptr %245, align 4, !alias.scope !1, !noalias !2
  %247 = icmp ne i32 %246, %232
  br i1 %247, label %248, label %251, !prof !0

248:
  %249 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %250 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %249, i64 %250)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 15)
  ret i32 1

251:
  %252 = and i32 %246, 1
  %253 = icmp ne i32 %252, 0
  br i1 %253, label %254, label %257, !prof !0

254:
  %255 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %256 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %255, i64 %256)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 15)
  ret i32 1

257:
  %258 = getelementptr inbounds i8, ptr %244, i64 16
  %259 = load i64, ptr %258, align 8!alias.scope !1, !noalias !2
  %260 = load ptr, ptr %244, align 8, !alias.scope !1, !noalias !2
  %261 = call { i64, i1 } @llvm.ssub.with.overflow.i64(i64 %259, i64 1)
  %262 = extractvalue { i64, i1 } %261, 0
  %263 = extractvalue { i64, i1 } %261, 1
  br i1 %263, label %264, label %267, !prof !0

264:
  %265 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 16 }, 0
  %266 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %265, i64 %266)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 17)
  ret i32 1

267:
  %268 = trunc i64 %228 to i32
  %269 = lshr i64 %228, 32
  %270 = trunc i64 %269 to i32
  %271 = icmp eq i32 %268, -1
  br i1 %271, label %272, label %275, !prof !0

272:
  %273 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %274 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %273, i64 %274)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 18)
  ret i32 1

275:
  %276 = getelementptr inbounds i8, ptr %1, i64 96
  %277 = load ptr, ptr %276, align 8!alias.scope !1, !noalias !2
  %278 = zext i32 %268 to i64
  %279 = mul nsw i64 %278, 112
  %280 = getelementptr inbounds i8, ptr %277, i64 %279
  %281 = getelementptr inbounds i8, ptr %280, i64 96
  %282 = load i32, ptr %281, align 4, !alias.scope !1, !noalias !2
  %283 = icmp ne i32 %282, %270
  br i1 %283, label %284, label %287, !prof !0

284:
  %285 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %286 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %285, i64 %286)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 18)
  ret i32 1

287:
  %288 = and i32 %282, 1
  %289 = icmp ne i32 %288, 0
  br i1 %289, label %290, label %293, !prof !0

290:
  %291 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %292 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %291, i64 %292)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 18)
  ret i32 1

293:
  %294 = getelementptr inbounds i8, ptr %280, i64 16
  %295 = load i64, ptr %294, align 8!alias.scope !1, !noalias !2
  %296 = load ptr, ptr %280, align 8, !alias.scope !1, !noalias !2
  %297 = icmp slt i64 %262, 0
  %298 = icmp sge i64 %262, %295
  %299 = or i1 %297, %298
  br i1 %299, label %300, label %303, !prof !0

300:
  %301 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 19 }, 0
  %302 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 10, ptr %301, i64 %302)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 18)
  ret i32 1

303:
  %304 = mul nsw i64 0, %295
  %305 = add nsw i64 %304, %262
  %306 = getelementptr inbounds i64, ptr %296, i64 %305
  %307 = load i64, ptr %306, align 8!alias.scope !2, !noalias !1
  %308 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 3
  store i64 %307, ptr %308, align 8
  %309 = call i32 @luce_rt_str(ptr %1, ptr %42, ptr %45)
  %310 = icmp ne i32 %309, 0
  br i1 %310, label %311, label %312, !prof !0

311:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 19)
  ret i32 1

312:
  %313 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 3
  %314 = load i64, ptr %313, align 8
  %315 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 1
  %316 = load i8, ptr %315, align 1
  %317 = icmp eq i8 %316, -1
  %318 = inttoptr i64 %314 to ptr
  %319 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 2
  %320 = select i1 %317, ptr %318, ptr %319
  %321 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 4
  %322 = load i64, ptr %321, align 8
  %323 = zext i8 %316 to i64
  %324 = select i1 %317, i64 %322, i64 %323
  %325 = insertvalue { ptr, i64 } poison, ptr %320, 0
  %326 = insertvalue { ptr, i64 } %325, i64 %324, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %45, i64 24, i1 false)
  %327 = extractvalue { ptr, i64 } %326, 0
  %328 = extractvalue { ptr, i64 } %326, 1
  %329 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %330 = load ptr, ptr %329, align 8
  %331 = icmp eq ptr %330, null
  br i1 %331, label %332, label %335, !prof !0

332:
  %333 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %334 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %333, i64 %334)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 21)
  ret i32 1

335:
  %336 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %337 = load ptr, ptr %336, align 8
  %338 = call i32 %330(ptr %337, ptr %327, i64 %328)
  %339 = icmp eq i32 %338, -1
  br i1 %339, label %340, label %341, !prof !0

340:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

341:
  %342 = icmp ne i32 %338, 0
  %343 = icmp ne i32 %338, 1
  %344 = and i1 %342, %343
  br i1 %344, label %345, label %348, !prof !0

345:
  %346 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %347 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %346, i64 %347)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 21)
  ret i32 1

348:
  %349 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %350 = load i64, ptr %349, align 8
  %351 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  %352 = load i8, ptr %351, align 1
  %353 = icmp eq i8 %352, -1
  %354 = inttoptr i64 %350 to ptr
  %355 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 2
  %356 = select i1 %353, ptr %354, ptr %355
  %357 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  %358 = load i64, ptr %357, align 8
  %359 = zext i8 %352 to i64
  %360 = select i1 %353, i64 %358, i64 %359
  %361 = insertvalue { ptr, i64 } poison, ptr %356, 0
  %362 = insertvalue { ptr, i64 } %361, i64 %360, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %9, ptr %46)
  %363 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %46, i32 0, i32 3
  %364 = load i64, ptr %363, align 8
  %365 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %46, i32 0, i32 1
  %366 = load i8, ptr %365, align 1
  %367 = icmp eq i8 %366, -1
  %368 = inttoptr i64 %364 to ptr
  %369 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %46, i32 0, i32 2
  %370 = select i1 %367, ptr %368, ptr %369
  %371 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %46, i32 0, i32 4
  %372 = load i64, ptr %371, align 8
  %373 = zext i8 %366 to i64
  %374 = select i1 %367, i64 %372, i64 %373
  %375 = insertvalue { ptr, i64 } poison, ptr %370, 0
  %376 = insertvalue { ptr, i64 } %375, i64 %374, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %46, i64 24, i1 false)
  %377 = load i64, ptr %8, align 8
  %378 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %47, i32 0, i32 3
  store i64 %377, ptr %378, align 8
  %379 = call i32 @luce_rt_release(ptr %1, ptr %47)
  %380 = icmp ne i32 %379, 0
  br i1 %380, label %381, label %382, !prof !0

381:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 26)
  ret i32 1

382:
  %383 = load i64, ptr %7, align 8
  %384 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 3
  store i64 %383, ptr %384, align 8
  %385 = call i32 @luce_rt_release(ptr %1, ptr %50)
  %386 = icmp ne i32 %385, 0
  br i1 %386, label %387, label %388, !prof !0

387:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 28)
  ret i32 1

388:
  ret i32 0
}

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #0

; Function Attrs: nounwind willreturn memory(readwrite)
declare i32 @luce_rt_new_list(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #1

; Function Attrs: nounwind willreturn memory(readwrite)
declare i32 @luce_rt_append(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %2) #1

; Function Attrs: nounwind willreturn memory(readwrite)
declare i32 @luce_rt_retain(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #1

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.ssub.with.overflow.i64(i64 %0, i64 %1) #2

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #4

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #5

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #6

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #7

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
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.8, i64 19)
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
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #1

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #9

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #7

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #10

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #10

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #11

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #11

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #7

attributes #0 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #1 = { nounwind willreturn memory(readwrite) }
attributes #2 = { nounwind speculatable willreturn nofree nosync nocallback memory(none) }
attributes #3 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #4 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #5 = { nounwind cold willreturn memory(argmem: write) }
attributes #6 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #7 = { nounwind memory(readwrite) }
attributes #8 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #9 = { nounwind willreturn memory(argmem: readwrite) }
attributes #10 = { cold }
attributes #11 = { nounwind willreturn memory(argmem: read) }

!0 = !{!"branch_weights", i32 1, i32 2000}
!1 = !{!4}
!2 = !{!5}
!3 = !{!"branch_weights", i32 2000, i32 1}
!4 = !{!"luce.rows", !6}
!5 = !{!"luce.elements", !6}
!6 = !{!"luce.alias"}
