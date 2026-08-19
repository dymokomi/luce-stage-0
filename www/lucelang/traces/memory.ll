; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/memory.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/memory.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.1 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.2 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.3 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.4 = private unnamed_addr constant [4 x i8] c"main"
@luce.text.5 = private unnamed_addr constant [57 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/memory.luc"
@luce.origins.0 = private constant [24 x { i32, i32 }] [{ i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }]
@luce.functions = private constant [1 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.4, i64 4, ptr @luce.text.5, i64 57, ptr @luce.origins.0, i64 24 }]
@luce.text.6 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
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
  store i8 6, ptr %31, align 1
  %32 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 4
  store i64 0, ptr %32, align 8
  %33 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %34 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %33, i32 0, i32 0
  store i8 2, ptr %34, align 1
  %35 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %33, i32 0, i32 4
  store i64 0, ptr %35, align 8
  %36 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %37 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 0
  store i8 2, ptr %37, align 1
  %38 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 4
  store i64 0, ptr %38, align 8
  %39 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %40 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %41 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %42 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 0
  store i8 6, ptr %42, align 1
  %43 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 4
  store i64 0, ptr %43, align 8
  %44 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %45 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 0
  store i8 6, ptr %45, align 1
  %46 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 4
  store i64 0, ptr %46, align 8
  br label %47

47:
  %48 = load i64, ptr %5, align 8
  %49 = trunc i64 %48 to i32
  %50 = lshr i64 %48, 32
  %51 = trunc i64 %50 to i32
  %52 = icmp eq i32 %49, -1
  br i1 %52, label %53, label %56, !prof !0

53:
  %54 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %55 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %54, i64 %55)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

56:
  %57 = getelementptr inbounds i8, ptr %1, i64 96
  %58 = load ptr, ptr %57, align 8!alias.scope !1, !noalias !2
  %59 = zext i32 %49 to i64
  %60 = mul nsw i64 %59, 112
  %61 = getelementptr inbounds i8, ptr %58, i64 %60
  %62 = getelementptr inbounds i8, ptr %61, i64 96
  %63 = load i32, ptr %62, align 4, !alias.scope !1, !noalias !2
  %64 = icmp ne i32 %63, %51
  br i1 %64, label %65, label %68, !prof !0

65:
  %66 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %67 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %66, i64 %67)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

68:
  %69 = and i32 %63, 1
  %70 = icmp ne i32 %69, 0
  br i1 %70, label %71, label %74, !prof !0

71:
  %72 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %73 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %72, i64 %73)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

74:
  %75 = getelementptr inbounds i8, ptr %61, i64 16
  %76 = load i64, ptr %75, align 8!alias.scope !1, !noalias !2
  %77 = load ptr, ptr %61, align 8, !alias.scope !1, !noalias !2
  %78 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 3
  store i64 0, ptr %78, align 8
  %79 = call i32 @luce_rt_new_list(ptr %1, ptr %17, ptr %20)
  %80 = icmp ne i32 %79, 0
  br i1 %80, label %81, label %82, !prof !0

81:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

82:
  %83 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 3
  %84 = load i64, ptr %83, align 8
  %85 = trunc i64 %84 to i32
  %86 = lshr i64 %84, 32
  %87 = trunc i64 %86 to i32
  %88 = icmp eq i32 %85, -1
  br i1 %88, label %89, label %92, !prof !0

89:
  %90 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %91 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %90, i64 %91)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 3)
  ret i32 1

92:
  %93 = getelementptr inbounds i8, ptr %1, i64 96
  %94 = load ptr, ptr %93, align 8!alias.scope !1, !noalias !2
  %95 = zext i32 %85 to i64
  %96 = mul nsw i64 %95, 112
  %97 = getelementptr inbounds i8, ptr %94, i64 %96
  %98 = getelementptr inbounds i8, ptr %97, i64 96
  %99 = load i32, ptr %98, align 4, !alias.scope !1, !noalias !2
  %100 = icmp ne i32 %99, %87
  br i1 %100, label %101, label %104, !prof !0

101:
  %102 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %103 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %102, i64 %103)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 3)
  ret i32 1

104:
  %105 = and i32 %99, 1
  %106 = icmp ne i32 %105, 0
  br i1 %106, label %107, label %110, !prof !0

107:
  %108 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %109 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %108, i64 %109)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 3)
  ret i32 1

110:
  %111 = getelementptr inbounds i8, ptr %97, i64 16
  %112 = load i64, ptr %111, align 8!alias.scope !1, !noalias !2
  %113 = getelementptr inbounds i8, ptr %97, i64 8
  %114 = load i64, ptr %113, align 8, !alias.scope !1, !noalias !2
  %115 = add nuw i64 %112, 1
  %116 = mul nuw i64 %115, 8
  %117 = icmp ule i64 %116, %114
  br i1 %117, label %118, label %121, !prof !3

118:
  %119 = load ptr, ptr %97, align 8!alias.scope !1, !noalias !2
  %120 = getelementptr inbounds i64, ptr %119, i64 %112
  store i64 %76, ptr %120, align 8, !alias.scope !2, !noalias !1
  store i64 %115, ptr %111, align 8, !alias.scope !1, !noalias !2
  br label %126

121:
  %122 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %21, i32 0, i32 3
  store i64 %84, ptr %122, align 8
  %123 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %24, i32 0, i32 3
  store i64 %76, ptr %123, align 8
  %124 = call i32 @luce_rt_append(ptr %1, ptr %21, ptr %24)
  %125 = icmp ne i32 %124, 0
  br i1 %125, label %131, label %132, !prof !0

126:
  store i64 %84, ptr %7, align 8
  %127 = load i64, ptr %7, align 8
  %128 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %27, i32 0, i32 3
  store i64 %127, ptr %128, align 8
  %129 = call i32 @luce_rt_retain(ptr %1, ptr %27)
  %130 = icmp ne i32 %129, 0
  br i1 %130, label %133, label %134, !prof !0

131:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 3)
  ret i32 1

132:
  br label %126

133:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 6)
  ret i32 1

134:
  store i64 %127, ptr %8, align 8
  %135 = load i64, ptr %8, align 8
  %136 = trunc i64 %135 to i32
  %137 = lshr i64 %135, 32
  %138 = trunc i64 %137 to i32
  %139 = icmp eq i32 %136, -1
  br i1 %139, label %140, label %143, !prof !0

140:
  %141 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %142 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %141, i64 %142)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 10)
  ret i32 1

143:
  %144 = getelementptr inbounds i8, ptr %1, i64 96
  %145 = load ptr, ptr %144, align 8!alias.scope !1, !noalias !2
  %146 = zext i32 %136 to i64
  %147 = mul nsw i64 %146, 112
  %148 = getelementptr inbounds i8, ptr %145, i64 %147
  %149 = getelementptr inbounds i8, ptr %148, i64 96
  %150 = load i32, ptr %149, align 4, !alias.scope !1, !noalias !2
  %151 = icmp ne i32 %150, %138
  br i1 %151, label %152, label %155, !prof !0

152:
  %153 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %154 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %153, i64 %154)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 10)
  ret i32 1

155:
  %156 = and i32 %150, 1
  %157 = icmp ne i32 %156, 0
  br i1 %157, label %158, label %161, !prof !0

158:
  %159 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %160 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %159, i64 %160)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 10)
  ret i32 1

161:
  %162 = getelementptr inbounds i8, ptr %148, i64 16
  %163 = load i64, ptr %162, align 8!alias.scope !1, !noalias !2
  %164 = getelementptr inbounds i8, ptr %148, i64 8
  %165 = load i64, ptr %164, align 8, !alias.scope !1, !noalias !2
  %166 = add nuw i64 %163, 1
  %167 = mul nuw i64 %166, 8
  %168 = icmp ule i64 %167, %165
  br i1 %168, label %169, label %172, !prof !3

169:
  %170 = load ptr, ptr %148, align 8!alias.scope !1, !noalias !2
  %171 = getelementptr inbounds i64, ptr %170, i64 %163
  store i64 42, ptr %171, align 8, !alias.scope !2, !noalias !1
  store i64 %166, ptr %162, align 8, !alias.scope !1, !noalias !2
  br label %177

172:
  %173 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 3
  store i64 %135, ptr %173, align 8
  %174 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %33, i32 0, i32 3
  store i64 42, ptr %174, align 8
  %175 = call i32 @luce_rt_append(ptr %1, ptr %30, ptr %33)
  %176 = icmp ne i32 %175, 0
  br i1 %176, label %183, label %184, !prof !0

177:
  %178 = load i64, ptr %7, align 8
  %179 = trunc i64 %178 to i32
  %180 = lshr i64 %178, 32
  %181 = trunc i64 %180 to i32
  %182 = icmp eq i32 %179, -1
  br i1 %182, label %185, label %188, !prof !0

183:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 10)
  ret i32 1

184:
  br label %177

185:
  %186 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %187 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %186, i64 %187)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 12)
  ret i32 1

188:
  %189 = getelementptr inbounds i8, ptr %1, i64 96
  %190 = load ptr, ptr %189, align 8!alias.scope !1, !noalias !2
  %191 = zext i32 %179 to i64
  %192 = mul nsw i64 %191, 112
  %193 = getelementptr inbounds i8, ptr %190, i64 %192
  %194 = getelementptr inbounds i8, ptr %193, i64 96
  %195 = load i32, ptr %194, align 4, !alias.scope !1, !noalias !2
  %196 = icmp ne i32 %195, %181
  br i1 %196, label %197, label %200, !prof !0

197:
  %198 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %199 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %198, i64 %199)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 12)
  ret i32 1

200:
  %201 = and i32 %195, 1
  %202 = icmp ne i32 %201, 0
  br i1 %202, label %203, label %206, !prof !0

203:
  %204 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %205 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %204, i64 %205)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 12)
  ret i32 1

206:
  %207 = getelementptr inbounds i8, ptr %193, i64 16
  %208 = load i64, ptr %207, align 8!alias.scope !1, !noalias !2
  %209 = load ptr, ptr %193, align 8, !alias.scope !1, !noalias !2
  %210 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %36, i32 0, i32 3
  store i64 %208, ptr %210, align 8
  %211 = call i32 @luce_rt_str(ptr %1, ptr %36, ptr %39)
  %212 = icmp ne i32 %211, 0
  br i1 %212, label %213, label %214, !prof !0

213:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 13)
  ret i32 1

214:
  %215 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 3
  %216 = load i64, ptr %215, align 8
  %217 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 1
  %218 = load i8, ptr %217, align 1
  %219 = icmp eq i8 %218, -1
  %220 = inttoptr i64 %216 to ptr
  %221 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 2
  %222 = select i1 %219, ptr %220, ptr %221
  %223 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %39, i32 0, i32 4
  %224 = load i64, ptr %223, align 8
  %225 = zext i8 %218 to i64
  %226 = select i1 %219, i64 %224, i64 %225
  %227 = insertvalue { ptr, i64 } poison, ptr %222, 0
  %228 = insertvalue { ptr, i64 } %227, i64 %226, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %39, i64 24, i1 false)
  %229 = extractvalue { ptr, i64 } %228, 0
  %230 = extractvalue { ptr, i64 } %228, 1
  %231 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %232 = load ptr, ptr %231, align 8
  %233 = icmp eq ptr %232, null
  br i1 %233, label %234, label %237, !prof !0

234:
  %235 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 24 }, 0
  %236 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %235, i64 %236)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 15)
  ret i32 1

237:
  %238 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %239 = load ptr, ptr %238, align 8
  %240 = call i32 %232(ptr %239, ptr %229, i64 %230)
  %241 = icmp eq i32 %240, -1
  br i1 %241, label %242, label %243, !prof !0

242:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

243:
  %244 = icmp ne i32 %240, 0
  %245 = icmp ne i32 %240, 1
  %246 = and i1 %244, %245
  br i1 %246, label %247, label %250, !prof !0

247:
  %248 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 24 }, 0
  %249 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %248, i64 %249)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 15)
  ret i32 1

250:
  %251 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %252 = load i64, ptr %251, align 8
  %253 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  %254 = load i8, ptr %253, align 1
  %255 = icmp eq i8 %254, -1
  %256 = inttoptr i64 %252 to ptr
  %257 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 2
  %258 = select i1 %255, ptr %256, ptr %257
  %259 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  %260 = load i64, ptr %259, align 8
  %261 = zext i8 %254 to i64
  %262 = select i1 %255, i64 %260, i64 %261
  %263 = insertvalue { ptr, i64 } poison, ptr %258, 0
  %264 = insertvalue { ptr, i64 } %263, i64 %262, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %9, ptr %40)
  %265 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %40, i32 0, i32 3
  %266 = load i64, ptr %265, align 8
  %267 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %40, i32 0, i32 1
  %268 = load i8, ptr %267, align 1
  %269 = icmp eq i8 %268, -1
  %270 = inttoptr i64 %266 to ptr
  %271 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %40, i32 0, i32 2
  %272 = select i1 %269, ptr %270, ptr %271
  %273 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %40, i32 0, i32 4
  %274 = load i64, ptr %273, align 8
  %275 = zext i8 %268 to i64
  %276 = select i1 %269, i64 %274, i64 %275
  %277 = insertvalue { ptr, i64 } poison, ptr %272, 0
  %278 = insertvalue { ptr, i64 } %277, i64 %276, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %40, i64 24, i1 false)
  %279 = load i64, ptr %8, align 8
  %280 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 3
  store i64 %279, ptr %280, align 8
  %281 = call i32 @luce_rt_release(ptr %1, ptr %41)
  %282 = icmp ne i32 %281, 0
  br i1 %282, label %283, label %284, !prof !0

283:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 20)
  ret i32 1

284:
  %285 = load i64, ptr %7, align 8
  %286 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %44, i32 0, i32 3
  store i64 %285, ptr %286, align 8
  %287 = call i32 @luce_rt_release(ptr %1, ptr %44)
  %288 = icmp ne i32 %287, 0
  br i1 %288, label %289, label %290, !prof !0

289:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 22)
  ret i32 1

290:
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
declare noalias ptr @luce_rt_open(ptr readonly %0, i64 %1) #7

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_files_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9, ptr %10, ptr %11) #8

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #1

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #8

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #6

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #9

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #9

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #10

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #10

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #6

attributes #0 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #1 = { nounwind willreturn memory(readwrite) }
attributes #2 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #3 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #4 = { nounwind cold willreturn memory(argmem: write) }
attributes #5 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #6 = { nounwind memory(readwrite) }
attributes #7 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #8 = { nounwind willreturn memory(argmem: readwrite) }
attributes #9 = { cold }
attributes #10 = { nounwind willreturn memory(argmem: read) }

!0 = !{!"branch_weights", i32 1, i32 2000}
!1 = !{!4}
!2 = !{!5}
!3 = !{!"branch_weights", i32 2000, i32 1}
!4 = !{!"luce.rows", !6}
!5 = !{!"luce.elements", !6}
!6 = !{!"luce.alias"}
