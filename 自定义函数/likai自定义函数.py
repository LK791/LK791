import random
import numpy as np
import pyautogui
import pandas as pd
import pyperclip
import time
import os
import win32com.client as win32
import pickle
import time
import datetime
from mootdx.reader import Reader




开始时间 = time.time()

np.set_printoptions(precision=None, suppress=True)
np.set_printoptions(threshold=np.inf)
# 设置输出右对齐
pd.set_option('display.unicode.east_asian_width', True)
# 显示所有的列
pd.set_option('expand_frame_repr', False)
# 最多显示数据的行数
pd.set_option('display.max_rows', 8000)
# 取消科学计数法,显示完整,可调整小数点后显示位数
pd.set_option('display.float_format', '{:.8f}'.format)








def MOFA_删除里面所有文件除了文件夹(已处理成xlsx路径 ) :
    # 删除目标文件夹下所有文件,只留空文件夹
    for root, dirs, files in os.walk(AA88):
        # 删除文件夹里的文件
        for file in files:
            file_path = os.path.join(root, file)
            os.remove(file_path)
    print('清理导出目录')
    print('* ' * 30)






def MOFA_转换xls(xls路径, 已处理成xlsx路径) :
    aaa = -1
    # 另存为xlsx的文件路径（GBK编码）
    for file in os.scandir(xls路径):
        suffix = file.name.split(".")[-1]
        if file.is_dir():
            pass
        else:
            if suffix == "xls":
                excel = win32.gencache.EnsureDispatch('Excel.Application')
                wb = excel.Workbooks.Open(file.path)
                # 将文件路径转换为GBK编码
                xlsx_path = 已处理成xlsx路径.encode('gbk')
                # xlsx文件夹路径\\文件名x
                wb.SaveAs(xlsx_path.decode('gbk') + "\\" + file.name + "x", FileFormat=51)
                wb.Close()
                excel.Application.Quit()
        aaa = aaa+1
        print( 'ok '+str(aaa)   )
    print('xls转换xlsx完成 ')
    print('* '*30)



def MOFA_删除里面所有文件除了文件夹(已处理成xlsx路径 ) :
    # 删除目标文件夹下所有文件,只留空文件夹
    for root, dirs, files in os.walk(已处理成xlsx路径):
        # 删除文件夹里的文件
        for file in files:
            file_path = os.path.join(root, file)
            os.remove(file_path)
    print('清理导出目录')
    print('* ' * 30)





def 读取拼接成df(文件夹路径):
    df_总 = pd.DataFrame()
    文件数 = 0
    文件列表 = []

    # 遍历文件夹中的所有文件
    for 文件名 in os.listdir(文件夹路径):
        if 文件名.endswith('.xlsx'):
            完整路径 = os.path.join(文件夹路径, 文件名)

            # 提取日期部分
            日期 = 文件名.replace('全部Ａ股', '').replace('.xlsx', '')

            try:
                日期 = pd.to_datetime(日期, format='%Y%m%d').date()
            except ValueError:
                print(f"日期格式错误: {日期}.")
                continue

            try:
                # 读取 Excel 文件
                df = pd.read_excel(完整路径, skiprows=1).iloc[:-1]

                # 加入日期列
                df['日期'] = 日期

                文件数 += 1
                print(f"已读取文件: {文件名}, 日期: {日期}, 累计处理文件数: {文件数}")

                文件列表.append(df)
            except Exception as e:
                print(f"读取文件 {文件名} 时发生错误: {e}")

    if 文件列表:
        # 将所有 DataFrame 合并
        df_总 = pd.concat(文件列表, ignore_index=True)

        # 将日期列设置为索引
        df_总.set_index('日期', inplace=True)

        # 将日期列复制到第一列
        df_总['日期'] = df_总.index

        # 调整列顺序，将日期列放在第一列
        列顺序 = ['日期'] + [col for col in df_总.columns if col != '日期']
        df_总 = df_总[列顺序]

        # 删除时分秒部分，只保留日期
        df_总.index = pd.to_datetime(df_总.index).date

    print(f"处理完成, 总共处理文件数: {文件数}")
    print('* ' * 30)
    df_总.columns = df_总.columns.str.strip()
    return df_总


def 读取通达信本地数据(股票代码列表, tdx_dir='C:/new_tdx'):
    """
    读取通达信本地数据，将所有股票的日线数据合并成一个 DataFrame，
    并将索引列（日期）复制到新列中，再将新列设置为索引。

    :param 股票代码列表: 股票代码的列表
    :param tdx_dir: 通达信数据目录
    :return: 合并后的 DataFrame
    """
    # 创建 Reader 对象
    reader = Reader.factory(market='std', tdxdir=tdx_dir)

    # 初始化一个空的 DataFrame 用于累积数据
    所有数据 = pd.DataFrame()

    # 遍历股票代码列表
    for 代码 in 股票代码列表:
        print(f"处理股票代码: {代码}")

        # 读取该股票的日线数据
        数据框 = reader.daily(symbol=代码)

        # 如果数据为空，则跳过该股票
        if 数据框.empty:
            print(f"{代码} 没有数据")
            continue

        # 确保索引是日期时间格式
        数据框.index = pd.to_datetime(数据框.index)

        # 复制索引列到第一列，并将其命名为 '日期'
        数据框['日期'] = 数据框.index.date

        # 保持原有索引列（即日期）
        数据框.index = pd.to_datetime(数据框.index)

        # 添加股票代码列
        数据框['股票代码'] = 代码

        # 确保 '股票代码' 列在最后一列
        数据框 = 数据框[['日期', '股票代码'] + [col for col in 数据框.columns if col not in ['日期', '股票代码']]]

        数据框.index = 数据框.index.date

        # 累积合并数据
        所有数据 = pd.concat([所有数据, 数据框], ignore_index=False)

    return 所有数据

def 时间列对齐数据补全(df, group_column='股票代码'):
    # 获取所有唯一日期
    unique_dates = sorted(df['日期'].unique())

    # 定义一个内部函数，用于处理每只股票的数据
    def process_stock(stock_df):
        # 对数据按日期对齐
        stock_df_aligned = stock_df.set_index('日期').reindex(unique_dates)

        # 将 'amount' 和 'volume' 列的空值填充为 0
        stock_df_aligned['amount'] = stock_df_aligned['amount'].fillna(0)
        stock_df_aligned['volume'] = stock_df_aligned['volume'].fillna(0)

        # 对其他列进行前向和后向填充
        stock_df_filled = stock_df_aligned.ffill().bfill()

        # 将填充后的 DataFrame 重置索引
        return stock_df_filled.reset_index()

    # 对每只股票应用处理函数，使用动态指定的分组列名
    processed_dfs = [process_stock(group) for _, group in df.groupby(group_column)]

    # 合并所有处理过的 DataFrame
    aligned_df = pd.concat(processed_dfs, ignore_index=True)

    return aligned_df








def 日期(date_int):
    year = date_int // 10000
    month = (date_int % 10000) // 100
    day = date_int % 100
    return datetime.date(year, month, day)




def zhao(数据框, 日期整数=0, 股票代码=0, 排序列=None, 排序方式=0):
    """
    筛选并排序数据框中的数据。

    参数:
    数据框 (pd.DataFrame): 要操作的数据框。
    日期整数 (int): 要筛选的日期，格式为 YYYYMMDD。如果为 0，则不进行日期筛选。
    股票代码 (int or str): 要筛选的股票代码。如果为 0，则不进行股票代码筛选。
    排序列 (str): 要排序的列名。如果为 None，则不进行排序。
    排序方式 (int): 排序方式，0 为降序，1 为升序。默认值为 0。

    返回:
    pd.DataFrame: 经过筛选和排序后的数据框。

    示例:
    1. 筛选日期:
        结果 = zhao(df, 20240816)

    2. 筛选日期和股票代码:
        结果 = zhao(df, 20240816, 1)  # 股票代码会被转换为 '000001'

    3. 筛选日期、股票代码，并按列排序:
        结果 = zhao(df, 20240816, 1, 排序列='国力天数', 排序方式=1)
    """
    # 如果日期不为 0，则将其转换为 datetime.date 对象并筛选数据
    if 日期整数 != 0:
        年 = 日期整数 // 10000
        月 = (日期整数 % 10000) // 100
        日 = 日期整数 % 100
        查询日期 = datetime.date(年, 月, 日)
        数据框 = 数据框[数据框['日期'] == 查询日期]

    # 将股票代码转换为字符串，并填充为6位
    if 股票代码 != 0:
        数据框 = 数据框[数据框['股票代码'] == str(股票代码).zfill(6)]  # 确保股票代码是6位

    # 如果提供了排序列，则进行排序
    if 排序列 is not None:
        升序 = True if 排序方式 == 1 else False
        数据框 = 数据框.sort_values(by=[排序列], ascending=升序)

    return 数据框





















# ---- MYTT 额外补充 ---------------------------------------------------



