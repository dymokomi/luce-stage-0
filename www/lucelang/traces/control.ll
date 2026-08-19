; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/control.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/control.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.dead.row = private constant <{ [96 x i8], i32, [12 x i8] }> <{ [96 x i8] zeroinitializer, i32 -1, [12 x i8] zeroinitializer }>, align 8
@luce.text.1 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.2 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.3 = private unnamed_addr constant [19 x i8] c"index out of bounds"
@luce.text.4 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.5 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.6 = private unnamed_addr constant [4 x i8] c"main"
@luce.text.7 = private unnamed_addr constant [58 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/control.luc"
@luce.origins.0 = private constant [40 x { i32, i32 }] [{ i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 4, i32 9 }, { i32, i32 } { i32 4, i32 9 }, { i32, i32 } { i32 4, i32 9 }, { i32, i32 } { i32 4, i32 9 }, { i32, i32 } { i32 4, i32 9 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 5, i32 13 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }]
@luce.functions = private constant [1 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.6, i64 4, ptr @luce.text.7, i64 58, ptr @luce.origins.0, i64 40 }]
@luce.text.8 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca i64, align 8
  %9 = alloca { ptr, i64 }, align 8
  %10 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  store i64 0, ptr %6, align 8
  store i64 4294967295, ptr %7, align 8
  store i64 0, ptr %8, align 8
  store { ptr, i64 } { ptr @luce.text.0, i64 0 }, ptr %9, align 8
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 0
  store i8 4, ptr %11, align 1
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 1
  store i8 -1, ptr %12, align 1
  %13 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %14 = ptrtoint ptr %13 to i64
  %15 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 3
  store i64 %14, ptr %15, align 8
  %16 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 4
  store i64 %16, ptr %17, align 8
  %18 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %19 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %18, i32 0, i32 0
  store i8 4, ptr %19, align 1
  %20 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %18, i32 0, i32 1
  store i8 -1, ptr %20, align 1
  %21 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %22 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 0
  store i8 2, ptr %23, align 1
  %24 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 4
  store i64 0, ptr %24, align 8
  %25 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %26 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %27

27:
  store i64 0, ptr %6, align 8
  %28 = load i64, ptr %5, align 8
  store i64 %28, ptr %7, align 8
  store i64 0, ptr %8, align 8
  %29 = load i64, ptr %7, align 8
  %30 = trunc i64 %29 to i32
  %31 = lshr i64 %29, 32
  %32 = trunc i64 %31 to i32
  %33 = getelementptr inbounds i8, ptr %1, i64 96
  %34 = load ptr, ptr %33, align 8!alias.scope !0, !noalias !1
  %35 = icmp eq i32 %30, -1
  %36 = zext i32 %30 to i64
  %37 = mul nsw i64 %36, 112
  %38 = getelementptr inbounds i8, ptr %34, i64 %37
  %39 = select i1 %35, ptr @luce.dead.row, ptr %38
  %40 = getelementptr inbounds i8, ptr %39, i64 96
  %41 = load i32, ptr %40, align 4, !alias.scope !0, !noalias !1
  %42 = load ptr, ptr %39, align 8, !alias.scope !0, !noalias !1
  %43 = getelementptr inbounds i8, ptr %39, i64 16
  %44 = load i64, ptr %43, align 8, !alias.scope !0, !noalias !1
  br label %45

45:
  %46 = load i64, ptr %7, align 8
  %47 = trunc i64 %46 to i32
  %48 = lshr i64 %46, 32
  %49 = trunc i64 %48 to i32
  %50 = icmp eq i32 %47, -1
  br i1 %50, label %74, label %77, !prof !2

51:
  %52 = load i64, ptr %7, align 8
  %53 = load i64, ptr %8, align 8
  %54 = trunc i64 %52 to i32
  %55 = lshr i64 %52, 32
  %56 = trunc i64 %55 to i32
  %57 = icmp eq i32 %54, -1
  br i1 %57, label %91, label %94, !prof !2

58:
  %59 = load i64, ptr %8, align 8
  %60 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %59, i64 1)
  %61 = extractvalue { i64, i1 } %60, 0
  %62 = extractvalue { i64, i1 } %60, 1
  br i1 %62, label %143, label %146, !prof !2

63:
  %64 = load i64, ptr %6, align 8
  %65 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 3
  store i64 %64, ptr %65, align 8
  %66 = call i32 @luce_rt_str(ptr %1, ptr %22, ptr %25)
  %67 = icmp ne i32 %66, 0
  br i1 %67, label %147, label %148, !prof !2

68:
  %69 = load i64, ptr %6, align 8
  %70 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %69, i64 1)
  %71 = extractvalue { i64, i1 } %70, 0
  %72 = extractvalue { i64, i1 } %70, 1
  br i1 %72, label %213, label %216, !prof !2

73:
  br label %58

74:
  %75 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %76 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %75, i64 %76)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 8)
  ret i32 1

77:
  %78 = icmp ne i32 %41, %49
  br i1 %78, label %79, label %82, !prof !2

79:
  %80 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %81 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %80, i64 %81)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 8)
  ret i32 1

82:
  %83 = and i32 %41, 1
  %84 = icmp ne i32 %83, 0
  br i1 %84, label %85, label %88, !prof !2

85:
  %86 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %87 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %86, i64 %87)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 8)
  ret i32 1

88:
  %89 = load i64, ptr %8, align 8
  %90 = icmp slt i64 %89, %44
  br i1 %90, label %51, label %63

91:
  %92 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %93 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %92, i64 %93)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 14)
  ret i32 1

94:
  %95 = icmp ne i32 %41, %56
  br i1 %95, label %96, label %99, !prof !2

96:
  %97 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %98 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %97, i64 %98)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 14)
  ret i32 1

99:
  %100 = and i32 %41, 1
  %101 = icmp ne i32 %100, 0
  br i1 %101, label %102, label %105, !prof !2

102:
  %103 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %104 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %103, i64 %104)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 14)
  ret i32 1

105:
  %106 = icmp slt i64 %53, 0
  %107 = icmp sge i64 %53, %44
  %108 = or i1 %106, %107
  br i1 %108, label %109, label %112, !prof !2

109:
  %110 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 0
  %111 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 19 }, 1
  call void @luce_rt_raise(ptr %1, i32 10, ptr %110, i64 %111)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 14)
  ret i32 1

112:
  %113 = mul nsw i64 0, %44
  %114 = add nsw i64 %113, %53
  %115 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i64 %114
  %116 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %115, i32 0, i32 3
  %117 = load i64, ptr %116, align 8
  %118 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %115, i32 0, i32 1
  %119 = load i8, ptr %118, align 1
  %120 = icmp eq i8 %119, -1
  %121 = inttoptr i64 %117 to ptr
  %122 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %115, i32 0, i32 2
  %123 = select i1 %120, ptr %121, ptr %122
  %124 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %115, i32 0, i32 4
  %125 = load i64, ptr %124, align 8
  %126 = zext i8 %119 to i64
  %127 = select i1 %120, i64 %125, i64 %126
  %128 = insertvalue { ptr, i64 } poison, ptr %123, 0
  %129 = insertvalue { ptr, i64 } %128, i64 %127, 1
  store { ptr, i64 } %129, ptr %9, align 8
  %130 = load { ptr, i64 }, ptr %9, align 8
  %131 = extractvalue { ptr, i64 } %130, 0
  %132 = ptrtoint ptr %131 to i64
  %133 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %18, i32 0, i32 3
  store i64 %132, ptr %133, align 8
  %134 = extractvalue { ptr, i64 } %130, 1
  %135 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %18, i32 0, i32 4
  store i64 %134, ptr %135, align 8
  %136 = call i32 @luce_rt_len(ptr %1, ptr %18, ptr %21)
  %137 = icmp ne i32 %136, 0
  br i1 %137, label %138, label %139, !prof !2

138:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 17)
  ret i32 1

139:
  %140 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %21, i32 0, i32 3
  %141 = load i64, ptr %140, align 8
  %142 = icmp sgt i64 %141, 2
  br i1 %142, label %68, label %73

143:
  %144 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 0
  %145 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %144, i64 %145)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 29)
  ret i32 1

146:
  store i64 %61, ptr %8, align 8
  br label %45

147:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 33)
  ret i32 1

148:
  %149 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 3
  %150 = load i64, ptr %149, align 8
  %151 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 1
  %152 = load i8, ptr %151, align 1
  %153 = icmp eq i8 %152, -1
  %154 = inttoptr i64 %150 to ptr
  %155 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 2
  %156 = select i1 %153, ptr %154, ptr %155
  %157 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 4
  %158 = load i64, ptr %157, align 8
  %159 = zext i8 %152 to i64
  %160 = select i1 %153, i64 %158, i64 %159
  %161 = insertvalue { ptr, i64 } poison, ptr %156, 0
  %162 = insertvalue { ptr, i64 } %161, i64 %160, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %10, ptr align 8 %25, i64 24, i1 false)
  %163 = extractvalue { ptr, i64 } %162, 0
  %164 = extractvalue { ptr, i64 } %162, 1
  %165 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %166 = load ptr, ptr %165, align 8
  %167 = icmp eq ptr %166, null
  br i1 %167, label %168, label %171, !prof !2

168:
  %169 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %170 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %169, i64 %170)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 35)
  ret i32 1

171:
  %172 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %173 = load ptr, ptr %172, align 8
  %174 = call i32 %166(ptr %173, ptr %163, i64 %164)
  %175 = icmp eq i32 %174, -1
  br i1 %175, label %176, label %177, !prof !2

176:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

177:
  %178 = icmp ne i32 %174, 0
  %179 = icmp ne i32 %174, 1
  %180 = and i1 %178, %179
  br i1 %180, label %181, label %184, !prof !2

181:
  %182 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 0
  %183 = extractvalue { ptr, i64 } { ptr @luce.text.5, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %182, i64 %183)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 35)
  ret i32 1

184:
  %185 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 3
  %186 = load i64, ptr %185, align 8
  %187 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 1
  %188 = load i8, ptr %187, align 1
  %189 = icmp eq i8 %188, -1
  %190 = inttoptr i64 %186 to ptr
  %191 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 2
  %192 = select i1 %189, ptr %190, ptr %191
  %193 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %10, i32 0, i32 4
  %194 = load i64, ptr %193, align 8
  %195 = zext i8 %188 to i64
  %196 = select i1 %189, i64 %194, i64 %195
  %197 = insertvalue { ptr, i64 } poison, ptr %192, 0
  %198 = insertvalue { ptr, i64 } %197, i64 %196, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %10, ptr %26)
  %199 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %26, i32 0, i32 3
  %200 = load i64, ptr %199, align 8
  %201 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %26, i32 0, i32 1
  %202 = load i8, ptr %201, align 1
  %203 = icmp eq i8 %202, -1
  %204 = inttoptr i64 %200 to ptr
  %205 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %26, i32 0, i32 2
  %206 = select i1 %203, ptr %204, ptr %205
  %207 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %26, i32 0, i32 4
  %208 = load i64, ptr %207, align 8
  %209 = zext i8 %202 to i64
  %210 = select i1 %203, i64 %208, i64 %209
  %211 = insertvalue { ptr, i64 } poison, ptr %206, 0
  %212 = insertvalue { ptr, i64 } %211, i64 %210, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %10, ptr align 8 %26, i64 24, i1 false)
  ret i32 0

213:
  %214 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 0
  %215 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %214, i64 %215)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 23)
  ret i32 1

216:
  store i64 %71, ptr %6, align 8
  br label %73
}

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #0

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite)
declare i32 @luce_rt_len(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #1

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %0, i64 %1) #2

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #4

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #5

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #6

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
  br i1 %14, label %15, label %16, !prof !2

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
  br i1 %63, label %64, label %65, !prof !2

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
  br i1 %72, label %77, label %78, !prof !2

73:
  %74 = load i32, ptr %3, align 8
  %75 = icmp eq i32 %74, 1
  %76 = icmp eq i32 %74, 2
  br i1 %75, label %83, label %86, !prof !2

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
  br i1 %76, label %87, label %90, !prof !2

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
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #10

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #10

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #11

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #11

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #12

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #12

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #10

attributes #0 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #1 = { nounwind willreturn memory(read, argmem: readwrite) }
attributes #2 = { nounwind speculatable willreturn nofree nosync nocallback memory(none) }
attributes #3 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #4 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #5 = { nounwind cold willreturn memory(argmem: write) }
attributes #6 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #7 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #8 = { nounwind willreturn memory(argmem: readwrite) }
attributes #9 = { nounwind willreturn memory(readwrite) }
attributes #10 = { nounwind memory(readwrite) }
attributes #11 = { cold }
attributes #12 = { nounwind willreturn memory(argmem: read) }

!0 = !{!3}
!1 = !{!4}
!2 = !{!"branch_weights", i32 1, i32 2000}
!3 = !{!"luce.rows", !5}
!4 = !{!"luce.elements", !5}
!5 = !{!"luce.alias"}
